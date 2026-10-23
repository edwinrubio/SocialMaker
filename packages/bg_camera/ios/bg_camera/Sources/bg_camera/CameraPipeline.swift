import AVFoundation
import CoreImage
import Flutter
import Vision

enum CameraError: LocalizedError {
  case noDevice
  case cannotAddInput
  case alreadyRecording
  case notRecording

  var errorDescription: String? {
    switch self {
    case .noDevice: return "No camera or microphone available"
    case .cannotAddInput: return "Cannot attach camera or microphone to the session"
    case .alreadyRecording: return "A segment is already being recorded"
    case .notRecording: return "No segment is being recorded"
    }
  }
}

/// Captures camera + microphone, replaces the background behind the person and
/// feeds the composited frames to a Flutter texture and, while recording, to a
/// `SegmentWriter`.
///
/// All frame work happens on `queue`; public mutators hop onto it.
final class CameraPipeline: NSObject, FlutterTexture,
  AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate
{
  static let outputWidth = 720
  static let outputHeight = 1280

  private(set) var textureId: Int64 = 0

  private let textures: FlutterTextureRegistry
  private let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "bg_camera.pipeline")
  private let videoOutput = AVCaptureVideoDataOutput()
  private let audioOutput = AVCaptureAudioDataOutput()
  private var videoInput: AVCaptureDeviceInput?
  private var position: AVCaptureDevice.Position = .front

  private let ciContext = CIContext(options: [.cacheIntermediates: false])
  private let segmentation: VNGeneratePersonSegmentationRequest = {
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .balanced
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    return request
  }()
  private let sequenceHandler = VNSequenceRequestHandler()
  private var bufferPool: CVPixelBufferPool?

  private let latestLock = NSLock()
  private var latestBuffer: CVPixelBuffer?

  private var writer: SegmentWriter?
  private var pendingStart = false

  private var _background: BackgroundSource?
  var background: BackgroundSource? {
    get { queue.sync { _background } }
    set { queue.async { self._background = newValue } }
  }

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
  }

  func start(position: AVCaptureDevice.Position) throws {
    self.position = position
    #if targetEnvironment(simulator)
      if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) == nil {
        try startSimulatorFeed()
        return
      }
    #endif
    session.beginConfiguration()
    do {
      try configureSession(position: position)
    } catch {
      // stopRunning() aborts the app while a configuration is still open.
      session.commitConfiguration()
      throw error
    }
    session.commitConfiguration()

    textureId = textures.register(self)
    queue.async { self.session.startRunning() }
  }

  private func configureSession(position: AVCaptureDevice.Position) throws {
    session.sessionPreset = .hd1280x720

    try attachCamera(position: position)

    guard let mic = AVCaptureDevice.default(for: .audio) else { throw CameraError.noDevice }
    let micInput = try AVCaptureDeviceInput(device: mic)
    guard session.canAddInput(micInput) else { throw CameraError.cannotAddInput }
    session.addInput(micInput)

    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: queue)
    guard session.canAddOutput(videoOutput) else { throw CameraError.cannotAddInput }
    session.addOutput(videoOutput)

    audioOutput.setSampleBufferDelegate(self, queue: queue)
    guard session.canAddOutput(audioOutput) else { throw CameraError.cannotAddInput }
    session.addOutput(audioOutput)

    configureVideoConnection()
  }

  func stop() {
    queue.sync {
      #if targetEnvironment(simulator)
        simulatorFeed?.stop()
      #endif
      session.stopRunning()
      writer?.cancel()
      writer = nil
      pendingStart = false
    }
    if textureId != 0 {
      textures.unregisterTexture(textureId)
      textureId = 0
    }
  }

  func switchCamera() {
    queue.async {
      let next: AVCaptureDevice.Position = self.position == .front ? .back : .front
      self.session.beginConfiguration()
      if let current = self.videoInput { self.session.removeInput(current) }
      do {
        try self.attachCamera(position: next)
        self.position = next
      } catch {
        try? self.attachCamera(position: self.position)
      }
      self.configureVideoConnection()
      self.session.commitConfiguration()
    }
  }

  func startSegment() throws {
    try queue.sync {
      if writer != nil || pendingStart { throw CameraError.alreadyRecording }
      // The writer is created on the next video frame so its session starts
      // at a real frame timestamp.
      pendingStart = true
    }
  }

  func stopSegment(completion: @escaping (Result<RecordedSegment, Error>) -> Void) {
    queue.async {
      self.pendingStart = false
      guard let writer = self.writer else {
        completion(.failure(CameraError.notRecording))
        return
      }
      self.writer = nil
      writer.finish(completion: completion)
    }
  }

  // MARK: - FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    latestLock.lock()
    defer { latestLock.unlock() }
    guard let buffer = latestBuffer else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  // MARK: - Capture delegates

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    if output === audioOutput {
      writer?.appendAudio(sampleBuffer)
      return
    }
    guard let cameraBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    process(cameraBuffer, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
  }

  /// Composites one camera frame, shows it and records it. Runs on `queue`.
  private func process(_ cameraBuffer: CVPixelBuffer, at time: CMTime) {
    guard let frame = composite(cameraBuffer) else { return }

    latestLock.lock()
    latestBuffer = frame
    latestLock.unlock()
    textures.textureFrameAvailable(textureId)

    if pendingStart {
      pendingStart = false
      do {
        writer = try SegmentWriter(
          width: Self.outputWidth, height: Self.outputHeight, startTime: time)
      } catch {
        NSLog("bg_camera: cannot start segment: \(error)")
      }
    }
    writer?.appendVideo(frame, at: time)
  }

  // MARK: - Private

  #if targetEnvironment(simulator)
    private var simulatorFeed: SimulatorCameraFeed?

    /// Simulator only: video file as camera, microphone if the Mac provides one.
    private func startSimulatorFeed() throws {
      guard
        let feed = SimulatorCameraFeed(
          queue: queue, onFrame: { [weak self] buffer, time in self?.process(buffer, at: time) })
      else { throw CameraError.noDevice }
      simulatorFeed = feed

      session.beginConfiguration()
      if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
        let mic = AVCaptureDevice.default(for: .audio),
        let input = try? AVCaptureDeviceInput(device: mic),
        session.canAddInput(input), session.canAddOutput(audioOutput)
      {
        session.addInput(input)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(audioOutput)
      }
      session.commitConfiguration()

      textureId = textures.register(self)
      queue.async {
        self.session.startRunning()
        feed.start()
      }
    }
  #endif

  private func attachCamera(position: AVCaptureDevice.Position) throws {
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    else { throw CameraError.noDevice }
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
    session.addInput(input)
    videoInput = input
  }

  private func configureVideoConnection() {
    guard let connection = videoOutput.connection(with: .video) else { return }
    if #available(iOS 17.0, *) {
      if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    } else if connection.isVideoOrientationSupported {
      connection.videoOrientation = .portrait
    }
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = position == .front
    }
  }

  /// Renders the camera frame (with the background replaced, if any) into an
  /// output-sized buffer.
  private func composite(_ cameraBuffer: CVPixelBuffer) -> CVPixelBuffer? {
    let extent = CGRect(x: 0, y: 0, width: Self.outputWidth, height: Self.outputHeight)
    let camera = CIImage(cvPixelBuffer: cameraBuffer).aspectFilled(to: extent)
    var image = camera

    if let background = _background, let backgroundImage = background.image(for: extent) {
      try? sequenceHandler.perform([segmentation], on: cameraBuffer)
      if let maskBuffer = segmentation.results?.first?.pixelBuffer {
        let mask = CIImage(cvPixelBuffer: maskBuffer).aspectFilled(to: extent)
        image = camera.applyingFilter(
          "CIBlendWithMask",
          parameters: [kCIInputBackgroundImageKey: backgroundImage, kCIInputMaskImageKey: mask])
      }
    }

    guard let output = makeOutputBuffer() else { return nil }
    ciContext.render(image.cropped(to: extent), to: output)
    return output
  }

  private func makeOutputBuffer() -> CVPixelBuffer? {
    if bufferPool == nil {
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Self.outputWidth,
        kCVPixelBufferHeightKey as String: Self.outputHeight,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ]
      CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &bufferPool)
    }
    guard let pool = bufferPool else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    return buffer
  }
}

extension CIImage {
  /// Scales and centers the image so it covers `rect`, cropping the overflow.
  func aspectFilled(to rect: CGRect) -> CIImage {
    let scale = max(rect.width / extent.width, rect.height / extent.height)
    let scaled = transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let dx = rect.midX - scaled.extent.midX
    let dy = rect.midY - scaled.extent.midY
    return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: rect)
  }
}

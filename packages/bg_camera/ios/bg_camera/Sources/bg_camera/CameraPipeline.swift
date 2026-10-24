import AVFoundation
import CoreImage
import Flutter
import Vision

enum CameraError: LocalizedError {
  case noDevice
  case cannotAddInput
  case alreadyRecording
  case notRecording
  case dualUnsupported

  var errorDescription: String? {
    switch self {
    case .noDevice: return "No camera or microphone available"
    case .cannotAddInput: return "Cannot attach camera or microphone to the session"
    case .alreadyRecording: return "A segment is already being recorded"
    case .notRecording: return "No segment is being recorded"
    case .dualUnsupported: return "This device cannot use both cameras at once"
    }
  }
}

/// Recorded video size (portrait), capture preset and bit rate. Raw values
/// match the Dart enum.
enum OutputResolution: String, CaseIterable {
  case p720, p1080, p2160

  var width: Int { [.p720: 720, .p1080: 1080, .p2160: 2160][self]! }
  var height: Int { [.p720: 1280, .p1080: 1920, .p2160: 3840][self]! }
  var bitRate: Int { [.p720: 6_000_000, .p1080: 12_000_000, .p2160: 40_000_000][self]! }

  var preset: AVCaptureSession.Preset {
    switch self {
    case .p720: return .hd1280x720
    case .p1080: return .hd1920x1080
    case .p2160: return .hd4K3840x2160
    }
  }

  /// What the front camera can capture (the simulator feed upscales, so it
  /// stops at 1080p).
  static func supported() -> [OutputResolution] {
    guard
      let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    else { return [.p720, .p1080] }
    let supported = allCases.filter { camera.supportsSessionPreset($0.preset) }
    return supported.isEmpty ? [.p720] : supported
  }

  /// Sizes both cameras can capture at once (dual mode): the multi-camera
  /// formats of back and front must both cover them.
  static func dualSupported() -> [OutputResolution] {
    #if targetEnvironment(simulator)
      return CameraPipeline.dualSupported ? [.p720, .p1080] : []
    #else
      guard AVCaptureMultiCamSession.isMultiCamSupported else { return [] }
      let cameras = [AVCaptureDevice.Position.back, .front].map {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: $0)
      }
      return allCases.filter { resolution in
        cameras.allSatisfy { camera in
          camera?.formats.contains { $0.isMultiCamSupported && resolution.covers($0) } ?? false
        }
      }
    #endif
  }

  /// Frame rates (24, 30, 60) the front camera offers at this size.
  func supportedFrameRates() -> [Int] {
    guard
      let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    else { return [24, 30] }
    let rates = [24, 30, 60].filter { rate in
      camera.formats.contains { fits($0, frameRate: rate) }
    }
    return rates.isEmpty ? [30] : rates
  }

  /// Whether [format] covers this size (landscape) at [frameRate].
  func fits(_ format: AVCaptureDevice.Format, frameRate: Int) -> Bool {
    covers(format)
      && format.videoSupportedFrameRateRanges.contains {
        $0.minFrameRate <= Double(frameRate) && Double(frameRate) <= $0.maxFrameRate
      }
  }

  /// Whether [format] (landscape) is at least this size.
  func covers(_ format: AVCaptureDevice.Format) -> Bool {
    let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    return Int(size.width) >= height && Int(size.height) >= width
  }
}

/// Captures camera + microphone, replaces the background behind the person and
/// feeds the composited frames to a Flutter texture and, while recording, to a
/// `SegmentWriter`.
///
/// In dual mode both cameras run at once (AVCaptureMultiCamSession): the main
/// one fills the frame and the other is drawn as a picture-in-picture window,
/// so it is part of the recording too.
///
/// All frame work happens on `queue`; public mutators hop onto it.
final class CameraPipeline: NSObject, FlutterTexture,
  AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate
{
  let resolution: OutputResolution
  let frameRate: Int
  var outputWidth: Int { resolution.width }
  var outputHeight: Int { resolution.height }

  private(set) var textureId: Int64 = 0

  private let textures: FlutterTextureRegistry
  private var session = AVCaptureSession()
  private let queue = DispatchQueue(label: "bg_camera.pipeline")
  // Outputs are recreated with every session: an output that moved to a new
  // session makes the old one assert when it is freed.
  /// The camera in single mode; the back camera in dual mode.
  private var videoOutput = AVCaptureVideoDataOutput()
  /// The front camera in dual mode.
  private var frontOutput = AVCaptureVideoDataOutput()
  private var audioOutput = AVCaptureAudioDataOutput()
  private var cameraInputs: [AVCaptureDevice.Position: AVCaptureDeviceInput] = [:]
  /// The camera that fills the frame.
  private var position: AVCaptureDevice.Position = .front

  private var dual = false
  /// Latest frame of the picture-in-picture camera (dual mode).
  private var latestPip: CVPixelBuffer?
  /// Picture-in-picture window as fractions of the frame, top-left origin.
  private var pipRect = CGRect(x: 0.58, y: 0.42, width: 0.28, height: 0.28)

  private let ciContext = CIContext(options: [.cacheIntermediates: false])
  private let segmentation: VNGeneratePersonSegmentationRequest = {
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .balanced
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    return request
  }()
  /// Segments the picture-in-picture window: `.fast` is plenty at its size.
  private let windowSegmentation: VNGeneratePersonSegmentationRequest = {
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .fast
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    return request
  }()
  /// The window's camera usually delivers fewer frames than the main one
  /// composites: its mask is computed once per window frame, not per output
  /// frame (doing it per output frame starved the window's camera).
  private var windowMask: (source: CVPixelBuffer, mask: CVPixelBuffer)?
  private var bufferPool: CVPixelBufferPool?

  private let latestLock = NSLock()
  private var latestBuffer: CVPixelBuffer?

  /// Set on `queue`, also read from `audioQueue`.
  private var writer: SegmentWriter? {
    get {
      writerLock.lock()
      defer { writerLock.unlock() }
      return _writer
    }
    set {
      writerLock.lock()
      _writer = newValue
      writerLock.unlock()
    }
  }
  private var _writer: SegmentWriter?
  private let writerLock = NSLock()
  /// The microphone's own queue: reconfiguring the session on `queue` (e.g.
  /// switching cameras) must not hold up audio, or samples get dropped.
  private let audioQueue = DispatchQueue(label: "bg_camera.audio")
  private var pendingStart = false

  private var _background: BackgroundSource?
  var background: BackgroundSource? {
    get { queue.sync { _background } }
    set { queue.async { self._background = newValue } }
  }

  init(textures: FlutterTextureRegistry, resolution: OutputResolution, frameRate: Int) {
    self.textures = textures
    self.resolution = resolution
    self.frameRate = frameRate
    super.init()
    makeOutputs()
  }

  private func makeOutputs() {
    videoOutput = AVCaptureVideoDataOutput()
    frontOutput = AVCaptureVideoDataOutput()
    audioOutput = AVCaptureAudioDataOutput()
    for output in [videoOutput, frontOutput] {
      output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
      output.alwaysDiscardsLateVideoFrames = true
      output.setSampleBufferDelegate(self, queue: queue)
    }
    audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
  }

  /// Both cameras at once: real devices that support it, or the simulator
  /// feed (shown twice) so the layout can be tested.
  static var dualSupported: Bool {
    #if targetEnvironment(simulator)
      return SimulatorCameraFeed.videoURL != nil
    #else
      return AVCaptureMultiCamSession.isMultiCamSupported
    #endif
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
    session.sessionPreset = session.canSetSessionPreset(resolution.preset) ? resolution.preset : .high

    try attachCamera(position: position)

    guard let mic = AVCaptureDevice.default(for: .audio) else { throw CameraError.noDevice }
    let micInput = try AVCaptureDeviceInput(device: mic)
    guard session.canAddInput(micInput) else { throw CameraError.cannotAddInput }
    session.addInput(micInput)

    guard session.canAddOutput(videoOutput) else { throw CameraError.cannotAddInput }
    session.addOutput(videoOutput)

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

  /// Works while recording. In dual mode it swaps the main and the
  /// picture-in-picture cameras.
  func switchCamera() {
    queue.async {
      let next: AVCaptureDevice.Position = self.position == .front ? .back : .front
      if self.dual {
        self.position = next
        self.latestPip = nil  // Until the other camera's next frame.
        self.windowMask = nil
        return
      }
      self.session.beginConfiguration()
      if let current = self.cameraInputs[self.position] { self.session.removeInput(current) }
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

  /// [fraction] 0...1 over the useful zoom range (capped at 10×).
  func setZoom(_ fraction: Double) {
    queue.async {
      guard let device = self.cameraInputs[self.position]?.device,
        (try? device.lockForConfiguration()) != nil
      else {
        return
      }
      let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10)
      device.videoZoomFactor = 1 + CGFloat(min(max(fraction, 0), 1)) * (maxZoom - 1)
      device.unlockForConfiguration()
    }
  }

  /// Rebuilds the capture session with one or both cameras. Not while recording.
  func setDual(_ enabled: Bool, completion: @escaping (Error?) -> Void) {
    queue.async {
      guard enabled != self.dual else { return completion(nil) }
      #if targetEnvironment(simulator)
        if self.simulatorFeed != nil {
          self.dual = enabled
          self.latestPip = nil
          self.windowMask = nil
          return completion(nil)
        }
      #endif
      self.session.stopRunning()
      self.teardownSession()
      var failure: Error?
      do {
        if enabled {
          try self.configureMultiCam(width: self.resolution.height)
          // Over budget: two smaller feeds, except at 4K, which would then
          // be upscaled.
          if let multiCam = self.session as? AVCaptureMultiCamSession, multiCam.hardwareCost > 1 {
            if self.resolution == .p2160 { throw CameraError.dualUnsupported }
            self.teardownSession()
            try self.configureMultiCam(width: 1280)
            if let retry = self.session as? AVCaptureMultiCamSession, retry.hardwareCost > 1 {
              throw CameraError.dualUnsupported
            }
          }
        } else {
          try self.configureSingle()
        }
        self.dual = enabled
      } catch {
        NSLog("bg_camera: cannot switch dual mode: \(error)")
        failure = error
        self.teardownSession()
        try? self.configureSingle()
        self.dual = false
      }
      self.latestPip = nil
      self.windowMask = nil
      self.session.startRunning()
      completion(failure)
    }
  }

  /// [rect]: fractions of the frame, top-left origin.
  func setPictureInPicture(_ rect: CGRect) {
    queue.async { self.pipRect = rect }
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
    // By type: `audioOutput` itself is replaced on `queue`.
    if output is AVCaptureAudioDataOutput {
      writer?.appendAudio(sampleBuffer)
      return
    }
    guard let cameraBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    if dual {
      let source: AVCaptureDevice.Position = output === frontOutput ? .front : .back
      if source != position {
        latestPip = cameraBuffer
        return
      }
    }
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
          width: outputWidth, height: outputHeight, bitRate: bitRate, startTime: time)
      } catch {
        NSLog("bg_camera: cannot start segment: \(error)")
      }
    }
    writer?.appendVideo(frame, at: time)
  }

  // MARK: - Private

  #if targetEnvironment(simulator)
    private var simulatorFeed: SimulatorCameraFeed?

    /// Simulator only: a video file as camera and microphone.
    private func startSimulatorFeed() throws {
      guard
        let feed = SimulatorCameraFeed(
          queue: queue,
          onFrame: { [weak self] buffer, time in
            guard let self else { return }
            // One feed plays both cameras in dual mode.
            if self.dual { self.latestPip = buffer }
            self.process(buffer, at: time)
          },
          onAudio: { [weak self] sample in self?.writer?.appendAudio(sample) })
      else { throw CameraError.noDevice }
      simulatorFeed = feed

      textureId = textures.register(self)
      queue.async { feed.start() }
    }
  #endif

  private func attachCamera(position: AVCaptureDevice.Position) throws {
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    else { throw CameraError.noDevice }
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
    session.addInput(input)
    cameraInputs = [position: input]
    applyFrameRate(device)
  }

  /// Locks [device] to `frameRate`, switching to a format that offers it at
  /// the output size when the session preset's doesn't. Inside a session
  /// configuration.
  private func applyFrameRate(_ device: AVCaptureDevice) {
    let format =
      resolution.fits(device.activeFormat, frameRate: frameRate)
      ? device.activeFormat
      : device.formats.filter { resolution.fits($0, frameRate: frameRate) }.min {
        let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
        let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
        return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
      }
    guard let format, (try? device.lockForConfiguration()) != nil else { return }
    if format != device.activeFormat { device.activeFormat = format }
    let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
    device.activeVideoMinFrameDuration = duration
    device.activeVideoMaxFrameDuration = duration
    device.unlockForConfiguration()
  }

  /// More frames need more bits for the same quality.
  private var bitRate: Int { frameRate > 30 ? resolution.bitRate * 3 / 2 : resolution.bitRate }

  /// A fresh single-camera session with the current main camera. On `queue`.
  private func configureSingle() throws {
    makeOutputs()
    session = AVCaptureSession()
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    try configureSession(position: position)
  }

  private func teardownSession() {
    session.beginConfiguration()
    session.inputs.forEach(session.removeInput)
    session.outputs.forEach(session.removeOutput)
    session.commitConfiguration()
    cameraInputs = [:]
  }

  /// Back camera into `videoOutput`, front into `frontOutput`, each with an
  /// explicit connection, plus the microphone. On `queue`.
  private func configureMultiCam(width targetWidth: Int) throws {
    guard AVCaptureMultiCamSession.isMultiCamSupported else { throw CameraError.dualUnsupported }
    makeOutputs()
    let multiCam = AVCaptureMultiCamSession()
    session = multiCam
    multiCam.beginConfiguration()
    defer { multiCam.commitConfiguration() }

    // 4K only on phones where `OutputResolution.dualSupported()` has it.
    for (position, output) in [(AVCaptureDevice.Position.back, videoOutput), (.front, frontOutput)] {
      guard
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
      else { throw CameraError.noDevice }
      let input = try AVCaptureDeviceInput(device: device)
      guard multiCam.canAddInput(input), multiCam.canAddOutput(output) else {
        throw CameraError.cannotAddInput
      }
      multiCam.addInputWithNoConnections(input)
      multiCam.addOutputWithNoConnections(output)
      guard
        let port = input.ports(
          for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: position
        ).first
      else { throw CameraError.cannotAddInput }
      let connection = AVCaptureConnection(inputPorts: [port], output: output)
      guard multiCam.canAddConnection(connection) else { throw CameraError.cannotAddInput }
      multiCam.addConnection(connection)
      orient(connection, mirrored: position == .front)
      try selectMultiCamFormat(device, width: targetWidth)
      cameraInputs[position] = input
    }

    guard let mic = AVCaptureDevice.default(for: .audio) else { throw CameraError.noDevice }
    let micInput = try AVCaptureDeviceInput(device: mic)
    guard multiCam.canAddInput(micInput), multiCam.canAddOutput(audioOutput) else {
      throw CameraError.cannotAddInput
    }
    multiCam.addInputWithNoConnections(micInput)
    multiCam.addOutputWithNoConnections(audioOutput)
    guard let micPort = micInput.ports.first(where: { $0.mediaType == .audio }) else {
      throw CameraError.cannotAddInput
    }
    let micConnection = AVCaptureConnection(inputPorts: [micPort], output: audioOutput)
    guard multiCam.canAddConnection(micConnection) else { throw CameraError.cannotAddInput }
    multiCam.addConnection(micConnection)
  }

  /// The smallest multi-camera format at least [width] wide (landscape), or
  /// the largest one there is.
  private func selectMultiCamFormat(_ device: AVCaptureDevice, width: Int) throws {
    let formats = device.formats.filter(\.isMultiCamSupported).sorted {
      CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
        < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
    }
    guard
      let format = formats.first(where: {
        CMVideoFormatDescriptionGetDimensions($0.formatDescription).width >= width
      }) ?? formats.last
    else { throw CameraError.dualUnsupported }
    try device.lockForConfiguration()
    device.activeFormat = format
    device.unlockForConfiguration()
  }

  private func configureVideoConnection() {
    guard let connection = videoOutput.connection(with: .video) else { return }
    orient(connection, mirrored: position == .front)
  }

  /// Portrait, mirrored for the front camera (like a mirror).
  private func orient(_ connection: AVCaptureConnection, mirrored: Bool) {
    if #available(iOS 17.0, *) {
      if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    } else if connection.isVideoOrientationSupported {
      connection.videoOrientation = .portrait
    }
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = mirrored
    }
  }

  /// Renders the camera frame (with the background replaced, if any) into an
  /// output-sized buffer.
  private func composite(_ cameraBuffer: CVPixelBuffer) -> CVPixelBuffer? {
    let extent = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
    // In dual mode the background effect follows the front camera, the one
    // filming the person, whether it fills the frame or the small window.
    let mainHasBackground = !dual || position == .front
    var image = filled(cameraBuffer, to: extent, withBackground: mainHasBackground)

    if dual, let pip = latestPip {
      let frame = Self.pipFrame(pipRect, in: extent)
      let window = filled(
        pip, to: CGRect(origin: .zero, size: frame.size), withBackground: !mainHasBackground,
        isWindow: true).transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
      image = Self.addingPictureInPicture(window, to: image, at: frame)
    }

    guard let output = makeOutputBuffer() else { return nil }
    ciContext.render(image.cropped(to: extent), to: output)
    return output
  }

  /// [cameraBuffer] cropped to fill [extent], with the background behind the
  /// person replaced when [withBackground] and one is set.
  private func filled(
    _ cameraBuffer: CVPixelBuffer, to extent: CGRect, withBackground: Bool, isWindow: Bool = false
  ) -> CIImage {
    let frame = CIImage(cvPixelBuffer: cameraBuffer)
    let camera = frame.aspectFilled(to: extent)
    guard withBackground, let background = _background,
      let backgroundImage = background.image(for: extent, camera: camera)
    else { return camera }

    let mask: CIImage
    if let maskBuffer = personMask(for: cameraBuffer, isWindow: isWindow) {
      // Vision's mask has its own size and aspect ratio: stretch it over the
      // frame first, then crop it exactly like the camera.
      mask = Self.refined(CIImage(cvPixelBuffer: maskBuffer))
        .stretched(to: frame.extent)
        .aspectFilled(to: extent)
    } else {
      #if targetEnvironment(simulator)
        // Recent simulators can't run person segmentation ("E5RT is not
        // supported"): a centered oval stands in for the person.
        mask = Self.simulatorMask(in: extent)
      #else
        return camera
      #endif
    }
    return camera.applyingFilter(
      "CIBlendWithMask",
      parameters: [kCIInputBackgroundImageKey: backgroundImage, kCIInputMaskImageKey: mask])
  }

  /// Vision's person mask for [cameraBuffer].
  private func personMask(for cameraBuffer: CVPixelBuffer, isWindow: Bool) -> CVPixelBuffer? {
    if isWindow, let windowMask, windowMask.source === cameraBuffer { return windowMask.mask }
    let request = isWindow ? windowSegmentation : segmentation
    // A fresh handler per frame: VNSequenceRequestHandler smooths the mask
    // over time, which leaves a ghost of the previous pose when moving.
    try? VNImageRequestHandler(cvPixelBuffer: cameraBuffer).perform([request])
    let mask = request.results?.first?.pixelBuffer
    if isWindow { windowMask = mask.map { (cameraBuffer, $0) } }
    return mask
  }

  #if targetEnvironment(simulator)
    private static func simulatorMask(in extent: CGRect) -> CIImage {
      let radius = extent.width * 0.3
      return (CIFilter(
        name: "CIRadialGradient",
        parameters: [
          "inputCenter": CIVector(x: extent.midX, y: extent.midY), "inputRadius0": radius * 0.9,
          "inputRadius1": radius, "inputColor0": CIColor.white, "inputColor1": CIColor.black,
        ])?.outputImage ?? CIImage.empty())
        .transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
        .transformed(by: CGAffineTransform(scaleX: 1, y: 1.4))
        .transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY))
        .cropped(to: extent)
    }
  #endif

  /// The picture-in-picture window [rect] (fractions of [extent], top-left
  /// origin) in Core Image coordinates, whose origin is bottom-left.
  private static func pipFrame(_ rect: CGRect, in extent: CGRect) -> CGRect {
    CGRect(
      x: rect.minX * extent.width, y: (1 - rect.maxY) * extent.height,
      width: rect.width * extent.width, height: rect.height * extent.height
    ).integral
  }

  /// Draws [window], already sized to [frame], as a rounded window over [image].
  private static func addingPictureInPicture(
    _ window: CIImage, to image: CIImage, at frame: CGRect
  ) -> CIImage {
    let mask =
      CIFilter(
        name: "CIRoundedRectangleGenerator",
        parameters: [
          "inputExtent": CIVector(cgRect: frame), "inputRadius": frame.width * 0.1, "inputColor": CIColor.white,
        ]
      )?.outputImage ?? CIImage.empty()
    return window.applyingFilter(
      "CIBlendWithMask",
      parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
  }

  /// Pulls the mask's edge slightly inside the person and softens it, so no
  /// rim of the real background shows around the silhouette.
  private static func refined(_ mask: CIImage) -> CIImage {
    mask.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1])
      .clampedToExtent()
      .applyingGaussianBlur(sigma: 1)
      .cropped(to: mask.extent)
  }

  private func makeOutputBuffer() -> CVPixelBuffer? {
    if bufferPool == nil {
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: outputWidth,
        kCVPixelBufferHeightKey as String: outputHeight,
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
  /// Scales the image to exactly `rect`, ignoring its aspect ratio.
  func stretched(to rect: CGRect) -> CIImage {
    transformed(
      by: CGAffineTransform(scaleX: rect.width / extent.width, y: rect.height / extent.height)
    ).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
  }

  /// Scales and centers the image so it covers `rect`, cropping the overflow.
  func aspectFilled(to rect: CGRect) -> CIImage {
    let scale = max(rect.width / extent.width, rect.height / extent.height)
    let scaled = transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let dx = rect.midX - scaled.extent.midX
    let dy = rect.midY - scaled.extent.midY
    return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: rect)
  }
}

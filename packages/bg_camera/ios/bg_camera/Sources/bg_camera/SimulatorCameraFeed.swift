#if targetEnvironment(simulator)
  import AVFoundation

  /// The iOS Simulator has no camera. To exercise the rest of the pipeline
  /// (recording, merge) there, this loops a video as the camera feed, from
  /// `~/Library/Caches/SocialMaker/fake_camera.mp4` on the Mac (survives app
  /// reinstalls) or `Documents/fake_camera.mp4` in the app container.
  /// Not compiled into device builds.
  final class SimulatorCameraFeed {
    static var videoURL: URL? {
      var candidates = [
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("fake_camera.mp4")
      ]
      if let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] {
        candidates.append(
          URL(fileURLWithPath: hostHome).appendingPathComponent("Library/Caches/SocialMaker/fake_camera.mp4"))
      }
      return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private let videoURL: URL

    private let queue: DispatchQueue
    private let onFrame: (CVPixelBuffer, CMTime) -> Void
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var timer: DispatchSourceTimer?

    init?(queue: DispatchQueue, onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
      guard let videoURL = Self.videoURL else { return nil }
      self.videoURL = videoURL
      self.queue = queue
      self.onFrame = onFrame
    }

    /// Must be called on `queue`.
    func start() {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: .milliseconds(33))
      timer.setEventHandler { [weak self] in self?.nextFrame() }
      timer.resume()
      self.timer = timer
    }

    /// Must be called on `queue`.
    func stop() {
      timer?.cancel()
      timer = nil
      reader?.cancelReading()
    }

    private func nextFrame() {
      if reader?.status != .reading { restart() }
      guard let sample = output?.copyNextSampleBuffer(),
        let buffer = CMSampleBufferGetImageBuffer(sample)
      else {
        reader = nil  // End of the file: loop on the next tick.
        return
      }
      // Same clock as the microphone samples from AVCaptureSession.
      onFrame(buffer, CMClockGetTime(CMClockGetHostTimeClock()))
    }

    private func restart() {
      let asset = AVURLAsset(url: videoURL)
      guard let track = asset.tracks(withMediaType: .video).first,
        let reader = try? AVAssetReader(asset: asset)
      else { return }
      let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
      reader.add(output)
      reader.startReading()
      self.reader = reader
      self.output = output
    }
  }
#endif

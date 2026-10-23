#if targetEnvironment(simulator)
  import AVFoundation

  /// The iOS Simulator has no camera. To exercise the rest of the pipeline
  /// (recording, merge, subtitles) there, this loops a video as the camera
  /// feed — and its soundtrack as the microphone — from
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
    private let onAudio: (CMSampleBuffer) -> Void
    private var reader: AVAssetReader?
    private var videoOutput: AVAssetReaderTrackOutput?
    private var audioOutput: AVAssetReaderTrackOutput?
    private var pendingVideo: CMSampleBuffer?
    private var pendingAudio: CMSampleBuffer?
    private var loopStart = CMTime.zero
    private var timer: DispatchSourceTimer?

    init?(
      queue: DispatchQueue, onFrame: @escaping (CVPixelBuffer, CMTime) -> Void,
      onAudio: @escaping (CMSampleBuffer) -> Void
    ) {
      guard let videoURL = Self.videoURL else { return nil }
      self.videoURL = videoURL
      self.queue = queue
      self.onFrame = onFrame
      self.onAudio = onAudio
    }

    /// Must be called on `queue`.
    func start() {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: .milliseconds(10))
      timer.setEventHandler { [weak self] in self?.tick() }
      timer.resume()
      self.timer = timer
    }

    /// Must be called on `queue`.
    func stop() {
      timer?.cancel()
      timer = nil
      reader?.cancelReading()
    }

    /// Plays the file in real time on the host clock (the microphone's clock).
    private func tick() {
      if reader?.status != .reading { restart() }
      let now = CMClockGetTime(CMClockGetHostTimeClock())
      let mediaTime = now - loopStart

      var latestFrame: CMSampleBuffer?
      while let frame = pendingVideo ?? videoOutput?.copyNextSampleBuffer() {
        pendingVideo = nil
        if CMSampleBufferGetPresentationTimeStamp(frame) > mediaTime {
          pendingVideo = frame
          break
        }
        latestFrame = frame
      }
      if let frame = latestFrame, let buffer = CMSampleBufferGetImageBuffer(frame) {
        onFrame(buffer, now)
      }

      // Like a microphone: each chunk only once its time has come.
      while let audio = pendingAudio ?? audioOutput?.copyNextSampleBuffer() {
        pendingAudio = nil
        if CMSampleBufferGetPresentationTimeStamp(audio) > mediaTime {
          pendingAudio = audio
          break
        }
        if let retimed = shifted(audio, by: loopStart) { onAudio(retimed) }
      }

      if pendingVideo == nil, pendingAudio == nil, latestFrame == nil, reader?.status == .completed {
        reader = nil  // End of the file: loop on the next tick.
      }
    }

    private func restart() {
      let asset = AVURLAsset(url: videoURL)
      guard let videoTrack = asset.tracks(withMediaType: .video).first,
        let reader = try? AVAssetReader(asset: asset)
      else { return }
      let videoOutput = AVAssetReaderTrackOutput(
        track: videoTrack,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
      reader.add(videoOutput)
      var audioOutput: AVAssetReaderTrackOutput?
      if let audioTrack = asset.tracks(withMediaType: .audio).first {
        let output = AVAssetReaderTrackOutput(
          track: audioTrack,
          outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
          ])
        reader.add(output)
        audioOutput = output
      }
      reader.startReading()
      self.reader = reader
      self.videoOutput = videoOutput
      self.audioOutput = audioOutput
      pendingVideo = nil
      pendingAudio = nil
      loopStart = CMClockGetTime(CMClockGetHostTimeClock())
    }

    private func shifted(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
      var count: CMItemCount = 0
      CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
      var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
      CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil)
      for i in timing.indices {
        timing[i].presentationTimeStamp = timing[i].presentationTimeStamp + offset
        timing[i].decodeTimeStamp = .invalid
      }
      var result: CMSampleBuffer?
      CMSampleBufferCreateCopyWithNewTiming(
        allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timing,
        sampleBufferOut: &result)
      return result
    }
  }
#endif

import AVFoundation

struct RecordedSegment {
  let url: URL
  let durationMs: Int
}

/// Writes one recorded fragment (H.264 + AAC) to a temporary .mp4.
/// Used only from the pipeline queue.
final class SegmentWriter {
  private let writer: AVAssetWriter
  private let videoInput: AVAssetWriterInput
  private let audioInput: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let startTime: CMTime
  private var lastVideoTime: CMTime

  init(width: Int, height: Int, startTime: CMTime) throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("segment_\(UUID().uuidString).mp4")
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

    videoInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
      ])
    videoInput.expectsMediaDataInRealTime = true
    adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)

    audioInput = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 96_000,
      ])
    audioInput.expectsMediaDataInRealTime = true

    writer.add(videoInput)
    writer.add(audioInput)
    guard writer.startWriting() else {
      throw writer.error ?? CameraError.cannotAddInput
    }
    writer.startSession(atSourceTime: startTime)
    self.startTime = startTime
    lastVideoTime = startTime
  }

  func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) {
    guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
    if adaptor.append(buffer, withPresentationTime: time) { lastVideoTime = time }
  }

  func appendAudio(_ sample: CMSampleBuffer) {
    guard writer.status == .writing, audioInput.isReadyForMoreMediaData,
      CMSampleBufferGetPresentationTimeStamp(sample) >= startTime
    else { return }
    audioInput.append(sample)
  }

  func finish(completion: @escaping (Result<RecordedSegment, Error>) -> Void) {
    let durationMs = Int((CMTimeGetSeconds(lastVideoTime - startTime) * 1000).rounded())
    videoInput.markAsFinished()
    audioInput.markAsFinished()
    writer.endSession(atSourceTime: lastVideoTime)
    writer.finishWriting { [writer] in
      if writer.status == .completed {
        completion(.success(RecordedSegment(url: writer.outputURL, durationMs: durationMs)))
      } else {
        completion(.failure(writer.error ?? CameraError.notRecording))
      }
    }
  }

  func cancel() {
    writer.cancelWriting()
    try? FileManager.default.removeItem(at: writer.outputURL)
  }
}

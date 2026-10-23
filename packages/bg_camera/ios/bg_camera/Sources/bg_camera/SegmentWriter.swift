import AVFoundation
import UIKit

struct RecordedSegment {
  let url: URL
  let durationMs: Int
  let thumbnailURL: URL?
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

  init(width: Int, height: Int, bitRate: Int, startTime: CMTime) throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("segment_\(UUID().uuidString).mp4")
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

    videoInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate],
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
        let thumbnail = Self.writeThumbnail(for: writer.outputURL)
        completion(
          .success(RecordedSegment(url: writer.outputURL, durationMs: durationMs, thumbnailURL: thumbnail)))
      } else {
        NSLog("bg_camera: segment failed: \(String(describing: writer.error))")
        completion(.failure(writer.error ?? CameraError.notRecording))
      }
    }
  }

  /// Saves the first frame next to the video as a small JPEG.
  private static func writeThumbnail(for video: URL) -> URL? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 240, height: 240)
    guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil),
      let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    else { return nil }
    let url = video.deletingPathExtension().appendingPathExtension("jpg")
    return (try? data.write(to: url)) != nil ? url : nil
  }

  func cancel() {
    writer.cancelWriting()
    try? FileManager.default.removeItem(at: writer.outputURL)
  }
}

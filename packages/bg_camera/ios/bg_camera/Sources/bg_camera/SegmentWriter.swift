import AVFoundation
import UIKit

struct RecordedSegment {
  let url: URL
  let durationMs: Int
  let thumbnailURL: URL?
}

/// Writes one recorded fragment (H.264 + AAC) to a temporary .mp4.
/// Video comes from the pipeline queue and audio from its own queue, so every
/// call is serialized with `lock`.
final class SegmentWriter {
  private let lock = NSLock()
  private let writer: AVAssetWriter
  private let videoInput: AVAssetWriterInput
  private let audioInput: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let startTime: CMTime
  private var lastVideoTime: CMTime
  /// Where the written audio ends; a later sample means audio was lost.
  private var audioEnd: CMTime?

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
    lock.lock()
    defer { lock.unlock() }
    guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
    if adaptor.append(buffer, withPresentationTime: time) { lastVideoTime = time }
  }

  func appendAudio(_ sample: CMSampleBuffer) {
    lock.lock()
    defer { lock.unlock() }
    let time = CMSampleBufferGetPresentationTimeStamp(sample)
    guard writer.status == .writing, audioInput.isReadyForMoreMediaData, time >= startTime
    else { return }
    // Audio samples are written back to back, whatever their timestamps: a
    // gap (microphone samples dropped while switching cameras) would pull
    // the rest of the audio ahead of the video. Fill it with silence.
    if let audioEnd, time - audioEnd > Self.maxAudioGap,
      let silence = Self.silence(like: sample, at: audioEnd, duration: time - audioEnd),
      audioInput.append(silence)
    {
      self.audioEnd = time
    }
    guard audioInput.isReadyForMoreMediaData, audioInput.append(sample) else { return }
    audioEnd = time + CMSampleBufferGetDuration(sample)
  }

  private static let maxAudioGap = CMTime(value: 1, timescale: 50)

  /// Silent PCM in [sample]'s format, from [time] for [duration].
  private static func silence(like sample: CMSampleBuffer, at time: CMTime, duration: CMTime)
    -> CMSampleBuffer?
  {
    guard let format = CMSampleBufferGetFormatDescription(sample),
      let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
      description.mFormatID == kAudioFormatLinearPCM, description.mBytesPerFrame > 0
    else { return nil }
    let frames = Int((CMTimeGetSeconds(duration) * description.mSampleRate).rounded())
    guard frames > 0 else { return nil }
    let nonInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let bytes =
      frames * Int(description.mBytesPerFrame) * (nonInterleaved ? Int(description.mChannelsPerFrame) : 1)
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
      let block,
      CMBlockBufferFillDataBytes(
        with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr
    else { return nil }
    var silence: CMSampleBuffer?
    guard
      CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
        sampleCount: frames, presentationTimeStamp: time, packetDescriptions: nil,
        sampleBufferOut: &silence) == noErr
    else { return nil }
    return silence
  }

  func finish(completion: @escaping (Result<RecordedSegment, Error>) -> Void) {
    lock.lock()
    defer { lock.unlock() }
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
    lock.lock()
    defer { lock.unlock() }
    writer.cancelWriting()
    try? FileManager.default.removeItem(at: writer.outputURL)
  }
}

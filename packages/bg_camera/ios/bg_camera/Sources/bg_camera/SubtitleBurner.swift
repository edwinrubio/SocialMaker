import AVFoundation
import CoreImage
import UIKit

struct CaptionSpec {
  let start: Double
  let end: Double
  let text: String
}

/// Renders captions into a copy of a video (TikTok style: bold white text with
/// a black outline, centered in the lower third).
enum SubtitleBurner {
  static func burn(
    video: URL, captions: [CaptionSpec], completion: @escaping (Result<URL, Error>) -> Void
  ) {
    let asset = AVURLAsset(url: video)
    guard let sourceVideo = asset.tracks(withMediaType: .video).first else {
      completion(.failure(MergeError.exportFailed("video has no image")))
      return
    }
    let duration = asset.duration
    let composition = AVMutableComposition()
    guard
      let videoTrack = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      completion(.failure(MergeError.exportFailed("cannot create tracks")))
      return
    }
    do {
      let range = CMTimeRange(start: .zero, duration: duration)
      try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
      if let sourceAudio = asset.tracks(withMediaType: .audio).first,
        let audioTrack = composition.addMutableTrack(
          withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      {
        try audioTrack.insertTimeRange(
          CMTimeRange(start: .zero, duration: min(duration, sourceAudio.timeRange.end)),
          of: sourceAudio, at: .zero)
      }
    } catch {
      completion(.failure(error))
      return
    }

    let transformed = sourceVideo.naturalSize.applying(sourceVideo.preferredTransform)
    let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))

    // Core Image instead of AVVideoCompositionCoreAnimationTool: same result,
    // no CALayer tree (which traps on the Simulator).
    let overlays = captions.filter { $0.end > $0.start }.map { caption in
      (caption, captionImage(caption.text, in: size))
    }
    let videoComposition = AVMutableVideoComposition(asset: composition) { request in
      let time = request.compositionTime.seconds
      var frame = request.sourceImage
      if let (_, image) = overlays.first(where: { time >= $0.0.start && time < $0.0.end }) {
        frame = image.composited(over: frame)
      }
      request.finish(with: frame.cropped(to: request.sourceImage.extent), context: nil)
    }
    videoComposition.renderSize = size
    videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("socialmaker_subs_\(UUID().uuidString).mp4")
    guard
      let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
    else {
      completion(.failure(MergeError.exportFailed("cannot create export session")))
      return
    }
    export.videoComposition = videoComposition
    export.outputURL = output
    export.outputFileType = .mp4
    export.exportAsynchronously {
      if export.status == .completed {
        completion(.success(output))
      } else {
        completion(.failure(export.error ?? MergeError.exportFailed("status \(export.status.rawValue)")))
      }
    }
  }

  /// The caption drawn once as an image, already placed in the lower third of
  /// a frame of [size] (Core Image's origin is bottom-left).
  private static func captionImage(_ string: String, in size: CGSize) -> CIImage {
    let fontSize = size.height * 0.045
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let shadow = NSShadow()
    shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
    shadow.shadowBlurRadius = fontSize * 0.08
    let text = NSAttributedString(
      string: string,
      attributes: [
        .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy),
        .foregroundColor: UIColor.white,
        .strokeColor: UIColor.black,
        .strokeWidth: -4.0,  // negative: fill and outline
        .paragraphStyle: paragraph,
        .shadow: shadow,
      ])

    let box = CGSize(width: size.width * 0.85, height: fontSize * 3.6)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let rendered = UIGraphicsImageRenderer(size: box, format: format).image { _ in
      let bounds = text.boundingRect(
        with: box, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
      // Bottom-aligned so one- and two-line captions sit on the same baseline.
      text.draw(
        with: CGRect(x: 0, y: box.height - ceil(bounds.height), width: box.width, height: ceil(bounds.height)),
        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
    guard let cgImage = rendered.cgImage else { return CIImage.empty() }
    return CIImage(cgImage: cgImage)
      .transformed(by: CGAffineTransform(translationX: size.width * 0.075, y: size.height * 0.14))
  }
}

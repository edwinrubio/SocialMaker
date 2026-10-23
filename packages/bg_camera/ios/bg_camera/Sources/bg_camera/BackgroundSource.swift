import AVFoundation
import CoreImage
import QuartzCore

/// Something drawn behind the person. Called on the pipeline queue.
protocol BackgroundSource: AnyObject {
  func image(for extent: CGRect) -> CIImage?
}

final class ImageBackground: BackgroundSource {
  private let source: CIImage
  private var cached: (extent: CGRect, image: CIImage)?

  init?(url: URL) {
    guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
      return nil
    }
    source = image
  }

  func image(for extent: CGRect) -> CIImage? {
    if let cached, cached.extent == extent { return cached.image }
    let image = source.aspectFilled(to: extent)
    cached = (extent, image)
    return image
  }
}

/// Loops a muted video and hands out its current frame.
final class VideoBackground: BackgroundSource {
  private let player: AVPlayer
  private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
  ])
  private let exifOrientation: Int32
  private var loopObserver: NSObjectProtocol?
  private var lastFrame: CIImage?

  init(url: URL) {
    let asset = AVURLAsset(url: url)
    exifOrientation = asset.tracks(withMediaType: .video).first?.preferredTransform.exifOrientation ?? 1
    let item = AVPlayerItem(asset: asset)
    item.add(output)
    player = AVPlayer(playerItem: item)
    player.isMuted = true
    player.actionAtItemEnd = .none
    loopObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [player] _ in
      player.seek(to: .zero)
    }
    player.play()
  }

  deinit {
    if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    player.pause()
  }

  func image(for extent: CGRect) -> CIImage? {
    let time = output.itemTime(forHostTime: CACurrentMediaTime())
    if output.hasNewPixelBuffer(forItemTime: time),
      let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    {
      lastFrame = CIImage(cvPixelBuffer: buffer)
        .oriented(forExifOrientation: exifOrientation)
        .aspectFilled(to: extent)
    }
    return lastFrame
  }
}

extension CGAffineTransform {
  /// Maps the rotation encoded in a video track's preferred transform to EXIF.
  fileprivate var exifOrientation: Int32 {
    switch (a, b, c, d) {
    case (0, 1, -1, 0): return 6  // rotated 90° (portrait recording)
    case (0, -1, 1, 0): return 8  // rotated 270°
    case (-1, 0, 0, -1): return 3  // rotated 180°
    default: return 1
    }
  }
}

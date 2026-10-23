import AVFoundation

enum MergeError: LocalizedError {
  case noSegments
  case exportFailed(String)

  var errorDescription: String? {
    switch self {
    case .noSegments: return "There are no segments to merge"
    case .exportFailed(let reason): return "Export failed: \(reason)"
    }
  }
}

/// Concatenates recorded segments, in order, into one .mp4.
enum SegmentMerger {
  static func merge(urls: [URL], completion: @escaping (Result<URL, Error>) -> Void) {
    guard !urls.isEmpty else {
      completion(.failure(MergeError.noSegments))
      return
    }
    let composition = AVMutableComposition()
    // Tracks are added only when a fragment has that media: an empty audio
    // track (fragments recorded without microphone) makes the export fail.
    var videoTrack: AVMutableCompositionTrack?
    var audioTrack: AVMutableCompositionTrack?

    var cursor = CMTime.zero
    do {
      for url in urls {
        let asset = AVURLAsset(url: url)
        let range = CMTimeRange(start: .zero, duration: asset.duration)
        if let video = asset.tracks(withMediaType: .video).first {
          if videoTrack == nil {
            videoTrack = composition.addMutableTrack(
              withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            videoTrack?.preferredTransform = video.preferredTransform
          }
          try videoTrack?.insertTimeRange(range, of: video, at: cursor)
        }
        if let audio = asset.tracks(withMediaType: .audio).first {
          if audioTrack == nil {
            audioTrack = composition.addMutableTrack(
              withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
          }
          try audioTrack?.insertTimeRange(
            CMTimeRange(start: .zero, duration: min(range.duration, audio.timeRange.end)), of: audio,
            at: cursor)
        }
        cursor = cursor + range.duration
      }
    } catch {
      completion(.failure(error))
      return
    }
    guard videoTrack != nil else {
      completion(.failure(MergeError.exportFailed("segments have no video")))
      return
    }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("socialmaker_\(UUID().uuidString).mp4")
    guard
      let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
    else {
      completion(.failure(MergeError.exportFailed("cannot create export session")))
      return
    }
    export.outputURL = outputURL
    export.outputFileType = .mp4
    export.shouldOptimizeForNetworkUse = true
    export.exportAsynchronously {
      if export.status == .completed {
        completion(.success(outputURL))
      } else {
        completion(.failure(export.error ?? MergeError.exportFailed("status \(export.status.rawValue)")))
      }
    }
  }
}

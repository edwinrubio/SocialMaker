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
    guard
      let videoTrack = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let audioTrack = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      completion(.failure(MergeError.exportFailed("cannot create tracks")))
      return
    }

    var cursor = CMTime.zero
    do {
      for url in urls {
        let asset = AVURLAsset(url: url)
        let range = CMTimeRange(start: .zero, duration: asset.duration)
        if let video = asset.tracks(withMediaType: .video).first {
          try videoTrack.insertTimeRange(range, of: video, at: cursor)
          videoTrack.preferredTransform = video.preferredTransform
        }
        if let audio = asset.tracks(withMediaType: .audio).first {
          try audioTrack.insertTimeRange(range, of: audio, at: cursor)
        }
        cursor = cursor + range.duration
      }
    } catch {
      completion(.failure(error))
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

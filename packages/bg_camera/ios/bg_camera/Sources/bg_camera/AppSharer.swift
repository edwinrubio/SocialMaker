import Photos
import UIKit

enum ShareError: LocalizedError {
  case photosDenied
  case saveFailed(String)

  var errorDescription: String? {
    switch self {
    case .photosDenied: return "Photos access denied"
    case .saveFailed(let reason): return reason
    }
  }
}

/// Hands the final video to TikTok, Instagram or YouTube on iOS without their
/// SDKs: the video is saved to Photos first (that is where these apps read
/// from), then the app is opened. Instagram takes the saved video directly
/// through its `instagram://library` link; TikTok and YouTube have no public
/// link for that, so they open with the video first in their gallery.
/// The schemes must be listed in the app's LSApplicationQueriesSchemes.
enum AppSharer {
  enum Outcome: String {
    /// The app opened with the video loaded (Instagram).
    case opened
    /// The app opened; the video is the newest one in Photos (TikTok, YouTube).
    case openedSaved
    case notInstalled
  }

  private static let schemes: [String: [String]] = [
    "instagram": ["instagram://app"],
    // snssdk1233 is TikTok's global app; "tiktok" covers newer builds.
    "tiktok": ["snssdk1233://", "tiktok://"],
    "youtube": ["youtube://"],
  ]

  /// Photos asset per exported file, so sharing twice doesn't save twice.
  private static var savedAssets: [String: String] = [:]

  /// Main thread only.
  static func share(
    video: URL, to app: String, completion: @escaping (Result<Outcome, Error>) -> Void
  ) {
    guard
      let appURL = schemes[app]?.compactMap(URL.init(string:))
        .first(where: UIApplication.shared.canOpenURL)
    else {
      completion(.success(.notInstalled))
      return
    }
    saveToPhotos(video) { saved in
      DispatchQueue.main.async {
        switch saved {
        case .failure(let error):
          completion(.failure(error))
        case .success(let localIdentifier):
          var target = appURL
          if app == "instagram" {
            var components = URLComponents(string: "instagram://library")!
            components.queryItems = [URLQueryItem(name: "LocalIdentifier", value: localIdentifier)]
            target = components.url ?? appURL
          }
          UIApplication.shared.open(target) { opened in
            completion(
              .success(!opened ? .notInstalled : app == "instagram" ? .opened : .openedSaved))
          }
        }
      }
    }
  }

  private static func saveToPhotos(_ video: URL, completion: @escaping (Result<String, Error>) -> Void) {
    if let id = savedAssets[video.path] {
      completion(.success(id))
      return
    }
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        completion(.failure(ShareError.photosDenied))
        return
      }
      var localIdentifier: String?
      PHPhotoLibrary.shared().performChanges({
        localIdentifier = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: video)?
          .placeholderForCreatedAsset?.localIdentifier
      }) { success, error in
        guard success, let localIdentifier else {
          completion(.failure(ShareError.saveFailed(error?.localizedDescription ?? "Cannot save video")))
          return
        }
        DispatchQueue.main.async { savedAssets[video.path] = localIdentifier }
        completion(.success(localIdentifier))
      }
    }
  }
}

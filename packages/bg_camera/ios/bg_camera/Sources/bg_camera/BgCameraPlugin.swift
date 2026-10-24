import AVFoundation
import Flutter
import UIKit

public class BgCameraPlugin: NSObject, FlutterPlugin {
  private let textures: FlutterTextureRegistry
  private var pipeline: CameraPipeline?

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "bg_camera", binaryMessenger: registrar.messenger())
    let instance = BgCameraPlugin(textures: registrar.textures())
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "requestPermissions":
      #if targetEnvironment(simulator)
        // Simulator feed (see SimulatorCameraFeed): nothing to ask for.
        if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) == nil {
          result(true)
          return
        }
      #endif
      AVCaptureDevice.requestAccess(for: .video) { video in
        AVCaptureDevice.requestAccess(for: .audio) { audio in
          DispatchQueue.main.async { result(video && audio) }
        }
      }
    case "supportedResolutions":
      result(OutputResolution.supported().map(\.rawValue))
    case "initialize":
      initialize(
        lens: args["lens"] as? String ?? "front",
        resolution: OutputResolution(rawValue: args["resolution"] as? String ?? "") ?? .p1080,
        frameRate: args["frameRate"] as? Int ?? 30,
        result: result)
    case "supportedFrameRates":
      let resolution = OutputResolution(rawValue: args["resolution"] as? String ?? "") ?? .p1080
      result(resolution.supportedFrameRates())
    case "setZoom":
      withPipeline(result) {
        $0.setZoom(args["fraction"] as? Double ?? 0)
        result(nil)
      }
    case "shareToApp":
      guard let path = args["path"] as? String, let app = args["app"] as? String else {
        result(FlutterError(code: "share_failed", message: "Missing arguments", details: nil))
        return
      }
      AppSharer.share(video: URL(fileURLWithPath: path), to: app) { outcome in
        switch outcome {
        case .success(let outcome): result(outcome.rawValue)
        case .failure(let error):
          result(FlutterError(code: "share_failed", message: error.localizedDescription, details: nil))
        }
      }
    case "dualCameraSupported":
      result(CameraPipeline.dualSupported)
    case "dualCameraResolutions":
      result(OutputResolution.dualSupported().map(\.rawValue))
    case "setDualCamera":
      withPipeline(result) { pipeline in
        pipeline.setDual(args["enabled"] as? Bool ?? false) { error in
          DispatchQueue.main.async {
            if let error {
              result(FlutterError(code: "dual_failed", message: error.localizedDescription, details: nil))
            } else {
              result(nil)
            }
          }
        }
      }
    case "setPictureInPicture":
      withPipeline(result) { pipeline in
        pipeline.setPictureInPicture(
          CGRect(
            x: args["x"] as? Double ?? 0, y: args["y"] as? Double ?? 0,
            width: args["width"] as? Double ?? 0, height: args["height"] as? Double ?? 0))
        result(nil)
      }
    case "subtitlesSupported":
      result(true)
    case "transcribe":
      transcribe(path: args["path"] as? String, localeId: args["locale"] as? String, result: result)
    case "burnSubtitles":
      burnSubtitles(path: args["path"] as? String, captions: args["captions"] as? [[String: Any]], result: result)
    case "setBackground":
      setBackground(
        type: args["type"] as? String ?? "none", path: args["path"] as? String,
        blurStrength: args["blurStrength"] as? Double ?? 0.5, result: result)
    case "switchCamera":
      withPipeline(result) { $0.switchCamera(); result(nil) }
    case "startSegment":
      withPipeline(result) { pipeline in
        do {
          try pipeline.startSegment()
          result(nil)
        } catch {
          result(FlutterError(code: "record_failed", message: error.localizedDescription, details: nil))
        }
      }
    case "stopSegment":
      withPipeline(result) { pipeline in
        pipeline.stopSegment { outcome in
          DispatchQueue.main.async {
            switch outcome {
            case .success(let segment):
              result([
                "path": segment.url.path,
                "durationMs": segment.durationMs,
                "thumbnailPath": segment.thumbnailURL?.path as Any,
              ])
            case .failure(let error):
              result(FlutterError(code: "record_failed", message: error.localizedDescription, details: nil))
            }
          }
        }
      }
    case "mergeSegments":
      let segments = args["segments"] as? [[String: Any]] ?? []
      let pieces = segments.compactMap { segment -> SegmentPiece? in
        guard let path = segment["path"] as? String else { return nil }
        let millis = { (key: String) in
          (segment[key] as? NSNumber).map { CMTime(value: $0.int64Value, timescale: 1000) }
        }
        return SegmentPiece(
          url: URL(fileURLWithPath: path), start: millis("startMs") ?? .zero, end: millis("endMs"))
      }
      SegmentMerger.merge(pieces: pieces) { outcome in
        DispatchQueue.main.async {
          switch outcome {
          case .success(let url): result(url.path)
          case .failure(let error):
            result(FlutterError(code: "merge_failed", message: error.localizedDescription, details: nil))
          }
        }
      }
    case "dispose":
      dispose()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func initialize(
    lens: String, resolution: OutputResolution, frameRate: Int, result: @escaping FlutterResult
  ) {
    dispose()
    let pipeline = CameraPipeline(textures: textures, resolution: resolution, frameRate: frameRate)
    do {
      try pipeline.start(position: lens == "back" ? .back : .front)
    } catch {
      pipeline.stop()
      result(FlutterError(code: "camera_unavailable", message: error.localizedDescription, details: nil))
      return
    }
    self.pipeline = pipeline
    result([
      "textureId": pipeline.textureId,
      "width": pipeline.outputWidth,
      "height": pipeline.outputHeight,
    ])
  }

  private func setBackground(
    type: String, path: String?, blurStrength: Double, result: @escaping FlutterResult
  ) {
    withPipeline(result) { pipeline in
      let url = path.map { URL(fileURLWithPath: $0) }
      switch (type, url) {
      case ("image", let url?):
        guard let source = ImageBackground(url: url) else {
          result(FlutterError(code: "bad_background", message: "Cannot read image \(url.path)", details: nil))
          return
        }
        pipeline.background = source
      case ("video", let url?):
        pipeline.background = VideoBackground(url: url)
      case ("blur", _):
        pipeline.background = BlurBackground(strength: blurStrength)
      default:
        pipeline.background = nil
      }
      result(nil)
    }
  }

  private func transcribe(path: String?, localeId: String?, result: @escaping FlutterResult) {
    guard let path else {
      result(FlutterError(code: "transcribe_failed", message: "Missing path", details: nil))
      return
    }
    let localeId = localeId ?? Locale.current.identifier
    Task {
      do {
        let words = try await Transcriber.transcribe(video: URL(fileURLWithPath: path), localeId: localeId)
        await MainActor.run { result(words.map(\.map)) }
      } catch {
        await MainActor.run {
          result(FlutterError(code: "transcribe_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func burnSubtitles(path: String?, captions: [[String: Any]]?, result: @escaping FlutterResult) {
    guard let path, let captions else {
      result(FlutterError(code: "subtitles_failed", message: "Missing arguments", details: nil))
      return
    }
    let specs = captions.compactMap { map -> CaptionSpec? in
      guard let start = map["startMs"] as? Int, let end = map["endMs"] as? Int,
        let text = map["text"] as? String
      else { return nil }
      return CaptionSpec(start: Double(start) / 1000, end: Double(end) / 1000, text: text)
    }
    SubtitleBurner.burn(video: URL(fileURLWithPath: path), captions: specs) { outcome in
      DispatchQueue.main.async {
        switch outcome {
        case .success(let url): result(url.path)
        case .failure(let error):
          result(FlutterError(code: "subtitles_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func withPipeline(_ result: @escaping FlutterResult, _ body: (CameraPipeline) -> Void) {
    guard let pipeline else {
      result(FlutterError(code: "not_initialized", message: "Call initialize first", details: nil))
      return
    }
    body(pipeline)
  }

  private func dispose() {
    pipeline?.stop()
    pipeline = nil
  }
}

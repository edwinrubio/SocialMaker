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
      AVCaptureDevice.requestAccess(for: .video) { video in
        AVCaptureDevice.requestAccess(for: .audio) { audio in
          DispatchQueue.main.async { result(video && audio) }
        }
      }
    case "initialize":
      initialize(lens: args["lens"] as? String ?? "front", result: result)
    case "setBackground":
      setBackground(type: args["type"] as? String ?? "none", path: args["path"] as? String, result: result)
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
              result(["path": segment.url.path, "durationMs": segment.durationMs])
            case .failure(let error):
              result(FlutterError(code: "record_failed", message: error.localizedDescription, details: nil))
            }
          }
        }
      }
    case "mergeSegments":
      let paths = args["paths"] as? [String] ?? []
      SegmentMerger.merge(urls: paths.map { URL(fileURLWithPath: $0) }) { outcome in
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

  private func initialize(lens: String, result: @escaping FlutterResult) {
    dispose()
    let pipeline = CameraPipeline(textures: textures)
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
      "width": CameraPipeline.outputWidth,
      "height": CameraPipeline.outputHeight,
    ])
  }

  private func setBackground(type: String, path: String?, result: @escaping FlutterResult) {
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
      default:
        pipeline.background = nil
      }
      result(nil)
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

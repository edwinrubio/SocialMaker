import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Which physical camera to capture from.
enum CameraLens { front, back }

/// What is drawn behind the segmented person.
enum BackgroundType { none, image, video }

/// Preview texture returned by [BgCamera.initialize].
@immutable
class CameraPreviewInfo {
  const CameraPreviewInfo({
    required this.textureId,
    required this.width,
    required this.height,
  });

  final int textureId;

  /// Size of the composited frame in pixels (portrait).
  final int width;
  final int height;

  double get aspectRatio => width / height;
}

/// A recorded video fragment on local storage.
@immutable
class RecordedSegment {
  const RecordedSegment({required this.path, required this.duration});

  final String path;
  final Duration duration;
}

/// Camera that segments the person and composites them over a background
/// natively, so both the preview and the recorded segments already have the
/// background replaced.
///
/// Call [requestPermissions] before [initialize].
class BgCamera {
  BgCamera({@visibleForTesting MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('bg_camera');

  final MethodChannel _channel;

  /// Asks for camera and microphone access; true when both are granted.
  Future<bool> requestPermissions() async =>
      await _channel.invokeMethod<bool>('requestPermissions') ?? false;

  Future<CameraPreviewInfo> initialize({
    CameraLens lens = CameraLens.front,
  }) async {
    final info = await _invokeMap('initialize', {'lens': lens.name});
    return CameraPreviewInfo(
      textureId: info['textureId'] as int,
      width: info['width'] as int,
      height: info['height'] as int,
    );
  }

  /// [path] is required unless [type] is [BackgroundType.none].
  Future<void> setBackground(BackgroundType type, {String? path}) {
    assert(type == BackgroundType.none || path != null);
    return _channel.invokeMethod<void>('setBackground', {
      'type': type.name,
      'path': path,
    });
  }

  Future<void> switchCamera() => _channel.invokeMethod<void>('switchCamera');

  Future<void> startSegment() => _channel.invokeMethod<void>('startSegment');

  Future<RecordedSegment> stopSegment() async {
    final info = await _invokeMap('stopSegment');
    return RecordedSegment(
      path: info['path'] as String,
      duration: Duration(milliseconds: info['durationMs'] as int),
    );
  }

  /// Concatenates [paths] in order into a single video and returns its path.
  Future<String> mergeSegments(List<String> paths) async {
    final path = await _channel.invokeMethod<String>('mergeSegments', {
      'paths': paths,
    });
    return path!;
  }

  Future<void> dispose() => _channel.invokeMethod<void>('dispose');

  Future<Map<Object?, Object?>> _invokeMap(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      method,
      arguments,
    );
    return result!;
  }
}

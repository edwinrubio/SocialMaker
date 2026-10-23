import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Which physical camera to capture from.
enum CameraLens { front, back }

/// What is drawn behind the segmented person.
enum BackgroundType { none, image, video, blur }

/// Output resolution of the recorded video (portrait).
enum VideoResolution {
  p720(720, 1280, '720p'),
  p1080(1080, 1920, '1080p'),
  p2160(2160, 3840, '4K');

  const VideoResolution(this.width, this.height, this.label);

  final int width;
  final int height;
  final String label;
}

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
  const RecordedSegment({
    required this.path,
    required this.duration,
    this.thumbnailPath,
  });

  final String path;
  final Duration duration;

  /// JPEG of the fragment's first frame, when one could be extracted.
  final String? thumbnailPath;
}

/// One subtitle phrase and when it is shown.
@immutable
class Caption {
  const Caption({required this.start, required this.end, required this.text});

  final Duration start;
  final Duration end;
  final String text;

  Caption copyWith({String? text}) =>
      Caption(start: start, end: end, text: text ?? this.text);

  Map<String, Object> toMap() => {
    'startMs': start.inMilliseconds,
    'endMs': end.inMilliseconds,
    'text': text,
  };

  static Caption fromMap(Map<Object?, Object?> map) => Caption(
    start: Duration(milliseconds: map['startMs'] as int),
    end: Duration(milliseconds: map['endMs'] as int),
    text: map['text'] as String,
  );

  @override
  bool operator ==(Object other) =>
      other is Caption &&
      other.start == start &&
      other.end == end &&
      other.text == text;

  @override
  int get hashCode => Object.hash(start, end, text);
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

  /// Resolutions this device can record (camera and encoder).
  Future<List<VideoResolution>> supportedResolutions() async {
    final names =
        await _channel.invokeListMethod<String>('supportedResolutions') ??
        const <String>[];
    return [
      for (final resolution in VideoResolution.values)
        if (names.contains(resolution.name)) resolution,
    ];
  }

  Future<CameraPreviewInfo> initialize({
    CameraLens lens = CameraLens.front,
    VideoResolution resolution = VideoResolution.p1080,
  }) async {
    final info = await _invokeMap('initialize', {
      'lens': lens.name,
      'resolution': resolution.name,
    });
    return CameraPreviewInfo(
      textureId: info['textureId'] as int,
      width: info['width'] as int,
      height: info['height'] as int,
    );
  }

  /// [path] is required for [BackgroundType.image] and [BackgroundType.video].
  Future<void> setBackground(BackgroundType type, {String? path}) {
    assert(
      type == BackgroundType.none ||
          type == BackgroundType.blur ||
          path != null,
    );
    return _channel.invokeMethod<void>('setBackground', {
      'type': type.name,
      'path': path,
    });
  }

  Future<void> switchCamera() => _channel.invokeMethod<void>('switchCamera');

  /// [fraction] goes from 0 (no zoom) to 1 (the camera's useful maximum).
  Future<void> setZoom(double fraction) => _channel.invokeMethod<void>(
    'setZoom',
    {'fraction': fraction.clamp(0.0, 1.0)},
  );

  Future<void> startSegment() => _channel.invokeMethod<void>('startSegment');

  Future<RecordedSegment> stopSegment() async {
    final info = await _invokeMap('stopSegment');
    return RecordedSegment(
      path: info['path'] as String,
      duration: Duration(milliseconds: info['durationMs'] as int),
      thumbnailPath: info['thumbnailPath'] as String?,
    );
  }

  /// Concatenates [paths] in order into a single video and returns its path.
  Future<String> mergeSegments(List<String> paths) async {
    final path = await _channel.invokeMethod<String>('mergeSegments', {
      'paths': paths,
    });
    return path!;
  }

  /// Whether on-device subtitles ([transcribe], [burnSubtitles]) exist here.
  Future<bool> subtitlesSupported() async =>
      await _channel.invokeMethod<bool>('subtitlesSupported') ?? false;

  /// Transcribes the speech in [path] on the device, as timed words (group
  /// them into phrases for display).
  /// [localeId] is a BCP-47 tag such as `es-CO`.
  Future<List<Caption>> transcribe(
    String path, {
    required String localeId,
  }) async {
    final list =
        await _channel.invokeListMethod<Map<Object?, Object?>>('transcribe', {
          'path': path,
          'locale': localeId,
        }) ??
        const [];
    return [for (final map in list) Caption.fromMap(map)];
  }

  /// Renders [captions] into a copy of the video at [path]; returns its path.
  Future<String> burnSubtitles(String path, List<Caption> captions) async {
    final result = await _channel.invokeMethod<String>('burnSubtitles', {
      'path': path,
      'captions': [for (final caption in captions) caption.toMap()],
    });
    return result!;
  }

  /// Android only: opens [app] (`tiktok`, `instagram`, `youtube`) with the
  /// video, or the system chooser when that app isn't installed (returns
  /// false then).
  Future<bool> shareToApp(String path, {String? app}) async =>
      await _channel.invokeMethod<bool>('shareToApp', {
        'path': path,
        'app': app,
      }) ??
      false;

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

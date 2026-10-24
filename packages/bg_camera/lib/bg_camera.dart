import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Which physical camera to capture from.
enum CameraLens { front, back }

/// What is drawn behind the segmented person.
enum BackgroundType { none, image, video, blur }

/// Corner of the frame where the second camera's window sits in dual mode.
enum PipCorner { topLeft, topRight, bottomLeft, bottomRight }

/// The picture-in-picture window for [corner], as fractions of the recorded
/// frame (top-left origin). The native renderer draws it there and the app's
/// overlay uses the same rect, so both always agree. It has the frame's aspect
/// ratio, which makes it square in these units.
Rect pipRectFor(PipCorner corner) {
  const size = 0.28;
  // Kept clear of the sides the preview crops on tall screens, of the top
  // bar, and of the bottom controls (and the apps' UI once shared).
  const side = 0.14;
  const top = 0.12;
  const bottom = 0.30;
  final left = corner == PipCorner.topLeft || corner == PipCorner.bottomLeft
      ? side
      : 1 - side - size;
  final y = corner == PipCorner.topLeft || corner == PipCorner.topRight
      ? top
      : 1 - bottom - size;
  return Rect.fromLTWH(left, y, size, size);
}

/// Result of [BgCamera.shareToApp].
enum ShareOutcome {
  /// The app opened with the video loaded.
  opened,

  /// The app opened; the video was saved to Photos for the user to pick.
  openedSaved,

  notInstalled,
}

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
  /// [blurStrength] (0 subtle to 1 strong) applies to [BackgroundType.blur].
  Future<void> setBackground(
    BackgroundType type, {
    String? path,
    double blurStrength = 0.5,
  }) {
    assert(
      type == BackgroundType.none ||
          type == BackgroundType.blur ||
          path != null,
    );
    return _channel.invokeMethod<void>('setBackground', {
      'type': type.name,
      'path': path,
      'blurStrength': blurStrength.clamp(0.0, 1.0),
    });
  }

  /// Works while recording; in dual mode it swaps the two cameras.
  Future<void> switchCamera() => _channel.invokeMethod<void>('switchCamera');

  /// Whether both cameras can record at once on this device.
  Future<bool> dualCameraSupported() async =>
      await _channel.invokeMethod<bool>('dualCameraSupported') ?? false;

  /// Records the other camera in a window at [setPictureInPicture]'s rect.
  /// Not while recording.
  Future<void> setDualCamera(bool enabled) =>
      _channel.invokeMethod<void>('setDualCamera', {'enabled': enabled});

  /// [rect] in fractions of the frame; see [pipRectFor].
  Future<void> setPictureInPicture(Rect rect) => _channel.invokeMethod<void>(
    'setPictureInPicture',
    {'x': rect.left, 'y': rect.top, 'width': rect.width, 'height': rect.height},
  );

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

  /// Opens [app] (`tiktok`, `instagram`, `youtube`) with the video.
  ///
  /// Android hands the file straight to the app. iOS saves it to Photos
  /// first: Instagram opens with it, TikTok and YouTube open with it as the
  /// newest video in their gallery ([ShareOutcome.openedSaved]).
  Future<ShareOutcome> shareToApp(String path, {required String app}) async {
    final outcome = await _channel.invokeMethod<String>('shareToApp', {
      'path': path,
      'app': app,
    });
    return ShareOutcome.values.firstWhere(
      (o) => o.name == outcome,
      orElse: () => ShareOutcome.notInstalled,
    );
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

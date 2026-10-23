import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_maker/features/recorder/recorder_controller.dart';
import 'package:social_maker/features/settings/settings_store.dart';

class MemorySettingsStore implements SettingsStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

/// Records fragments whose duration is set by the test.
class FakeBgCamera implements BgCamera {
  bool grantPermissions = true;
  Duration nextDuration = const Duration(seconds: 2);
  bool failNextStop = false;
  List<String>? mergedPaths;
  List<VideoResolution> supported = const [
    VideoResolution.p720,
    VideoResolution.p1080,
  ];
  VideoResolution? initializedWith;
  final zooms = <double>[];
  final backgrounds = <BackgroundType>[];
  final blurStrengths = <double>[];
  int disposeCount = 0;
  int _count = 0;

  @override
  Future<List<VideoResolution>> supportedResolutions() async => supported;

  @override
  Future<void> setZoom(double fraction) async => zooms.add(fraction);

  @override
  Future<bool> subtitlesSupported() async => false;

  @override
  Future<bool> shareToApp(String path, {String? app}) async => false;

  @override
  Future<List<Caption>> transcribe(
    String path, {
    required String localeId,
  }) async => const [];

  @override
  Future<String> burnSubtitles(String path, List<Caption> captions) async =>
      path;

  @override
  Future<bool> requestPermissions() async => grantPermissions;

  @override
  Future<CameraPreviewInfo> initialize({
    CameraLens lens = CameraLens.front,
    VideoResolution resolution = VideoResolution.p1080,
  }) async {
    initializedWith = resolution;
    return CameraPreviewInfo(
      textureId: 1,
      width: resolution.width,
      height: resolution.height,
    );
  }

  @override
  Future<void> startSegment() async {}

  @override
  Future<RecordedSegment> stopSegment() async {
    if (failNextStop) {
      failNextStop = false;
      throw PlatformException(code: 'record_failed', message: 'too short');
    }
    return RecordedSegment(
      path: '/fake/segment_${_count++}.mp4',
      duration: nextDuration,
    );
  }

  @override
  Future<String> mergeSegments(List<String> paths) async {
    mergedPaths = paths;
    return '/fake/out.mp4';
  }

  @override
  Future<void> setBackground(
    BackgroundType type, {
    String? path,
    double blurStrength = 0.5,
  }) async {
    backgrounds.add(type);
    blurStrengths.add(blurStrength);
  }

  @override
  Future<void> switchCamera() async {}

  @override
  Future<void> dispose() async => disposeCount++;
}

void main() {
  late FakeBgCamera camera;
  late MemorySettingsStore settings;
  late RecorderController controller;

  setUp(() async {
    camera = FakeBgCamera();
    settings = MemorySettingsStore();
    controller = RecorderController(
      camera: camera,
      settings: settings,
      maxDuration: const Duration(seconds: 10),
    );
    await controller.initialize();
  });

  Future<void> record(Duration duration) async {
    camera.nextDuration = duration;
    await controller.startSegment();
    await controller.stopSegment();
  }

  test('each hold creates a segment and durations add up', () async {
    await record(const Duration(seconds: 2));
    await record(const Duration(seconds: 3));
    await record(const Duration(seconds: 1));

    expect(controller.segments, hasLength(3));
    expect(controller.recordedDuration, const Duration(seconds: 6));
    expect(controller.isRecording, isFalse);
  });

  test(
    'deleting the middle segment keeps the others in order for export',
    () async {
      await record(const Duration(seconds: 1));
      await record(const Duration(seconds: 1));
      await record(const Duration(seconds: 1));

      controller.removeSegmentAt(1);
      await controller.export();

      expect(camera.mergedPaths, [
        '/fake/segment_0.mp4',
        '/fake/segment_2.mp4',
      ]);
      expect(controller.recordedDuration, const Duration(seconds: 2));
    },
  );

  test('remove last and clear', () async {
    await record(const Duration(seconds: 1));
    await record(const Duration(seconds: 2));

    controller.removeSelectedOrLastSegment();
    expect(controller.segments.single.path, '/fake/segment_0.mp4');

    controller.clearSegments();
    expect(controller.segments, isEmpty);
  });

  test('delete button removes the selected fragment', () async {
    await record(const Duration(seconds: 1));
    await record(const Duration(seconds: 1));
    await record(const Duration(seconds: 1));

    controller.toggleSelection(0);
    controller.removeSelectedOrLastSegment();
    expect(
      [for (final s in controller.segments) s.path],
      ['/fake/segment_1.mp4', '/fake/segment_2.mp4'],
    );
    expect(controller.selectedIndex, isNull);

    controller.toggleSelection(1);
    controller.toggleSelection(1);
    expect(controller.selectedIndex, isNull);
  });

  test('selection follows when an earlier fragment is removed', () async {
    await record(const Duration(seconds: 1));
    await record(const Duration(seconds: 1));
    await record(const Duration(seconds: 1));

    controller.toggleSelection(2);
    controller.removeSegmentAt(0);
    expect(controller.selectedIndex, 1);
  });

  test('cannot record once the limit is reached', () async {
    await record(const Duration(seconds: 10));

    expect(controller.canRecord, isFalse);
    await controller.startSegment();
    expect(controller.isRecording, isFalse);
  });

  test('a failed stop records nothing and reports the error', () async {
    camera.failNextStop = true;
    await controller.startSegment();
    await controller.stopSegment();

    expect(controller.segments, isEmpty);
    expect(controller.error, 'too short');
  });

  test('denied permissions leave no preview and an error', () async {
    final denied = FakeBgCamera()..grantPermissions = false;
    final c = RecorderController(camera: denied, settings: settings);
    await c.initialize();

    expect(c.preview, isNull);
    expect(c.error, isNotNull);
    expect(c.canRecord, isFalse);
  });

  test('defaults to 1080p, or the saved resolution when supported', () async {
    expect(camera.initializedWith, VideoResolution.p1080);

    final saved = MemorySettingsStore()
      ..values[RecorderController.resolutionKey] = 'p720';
    final other = FakeBgCamera();
    await RecorderController(camera: other, settings: saved).initialize();
    expect(other.initializedWith, VideoResolution.p720);

    final unsupported = MemorySettingsStore()
      ..values[RecorderController.resolutionKey] = 'p2160';
    final third = FakeBgCamera();
    await RecorderController(camera: third, settings: unsupported).initialize();
    expect(third.initializedWith, VideoResolution.p1080);
  });

  test('blur strength applies live and is remembered on release', () async {
    await controller.setBackground(BackgroundType.blur);
    camera.blurStrengths.clear();

    await controller.setBlurStrength(0.51); // too small a step
    await controller.setBlurStrength(0.8);
    await controller.setBlurStrength(0.8, done: true);

    expect(camera.blurStrengths, [0.8, 0.8]);
    expect(settings.values[RecorderController.blurStrengthKey], '0.8');
  });

  test('changing resolution clears fragments, saves it and reopens', () async {
    await record(const Duration(seconds: 1));
    await controller.setBackground(BackgroundType.blur);

    await controller.changeResolution(VideoResolution.p720);

    expect(controller.segments, isEmpty);
    expect(settings.values[RecorderController.resolutionKey], 'p720');
    expect(camera.disposeCount, 1);
    expect(camera.initializedWith, VideoResolution.p720);
    expect(controller.preview!.width, 720);
    // The background survives reopening the camera.
    expect(camera.backgrounds, [BackgroundType.blur, BackgroundType.blur]);
  });

  test('zoom ignores tiny changes and resets once', () {
    controller
      ..setZoom(0.5)
      ..setZoom(0.505)
      ..setZoom(0.6)
      ..setZoom(1.4)
      ..setZoom(0)
      ..setZoom(0);
    expect(camera.zooms, [0.5, 0.6, 1.0, 0]);
  });
}

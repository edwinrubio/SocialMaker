import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_maker/features/recorder/recorder_controller.dart';

/// Records fragments whose duration is set by the test.
class FakeBgCamera implements BgCamera {
  bool grantPermissions = true;
  Duration nextDuration = const Duration(seconds: 2);
  bool failNextStop = false;
  List<String>? mergedPaths;
  int _count = 0;

  @override
  Future<bool> requestPermissions() async => grantPermissions;

  @override
  Future<CameraPreviewInfo> initialize({
    CameraLens lens = CameraLens.front,
  }) async => const CameraPreviewInfo(textureId: 1, width: 720, height: 1280);

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
  Future<void> setBackground(BackgroundType type, {String? path}) async {}

  @override
  Future<void> switchCamera() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  late FakeBgCamera camera;
  late RecorderController controller;

  setUp(() async {
    camera = FakeBgCamera();
    controller = RecorderController(
      camera: camera,
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
    final c = RecorderController(camera: denied);
    await c.initialize();

    expect(c.preview, isNull);
    expect(c.error, isNotNull);
    expect(c.canRecord, isFalse);
  });
}

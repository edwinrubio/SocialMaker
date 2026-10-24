import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('bg_camera');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'initialize':
              return {'textureId': 7, 'width': 720, 'height': 1280};
            case 'stopSegment':
              return {
                'path': '/tmp/a.mp4',
                'durationMs': 1500,
                'thumbnailPath': '/tmp/a.jpg',
              };
            case 'mergeSegments':
              return '/tmp/out.mp4';
            case 'supportedResolutions':
              return ['p720', 'p1080'];
            case 'transcribe':
              return [
                {'startMs': 0, 'endMs': 1200, 'text': 'Hola a todos'},
                {'startMs': 1500, 'endMs': 2800, 'text': 'bienvenidos'},
              ];
            case 'burnSubtitles':
              return '/tmp/subs.mp4';
          }
          return null;
        });
  });

  test('initialize returns preview info', () async {
    final info = await BgCamera().initialize(lens: CameraLens.back);

    expect(calls.single.arguments, {
      'lens': 'back',
      'resolution': 'p1080',
      'frameRate': 30,
    });
    expect(info.textureId, 7);
    expect(info.aspectRatio, 720 / 1280);
  });

  test('stopSegment parses path and duration', () async {
    final segment = await BgCamera().stopSegment();

    expect(segment.path, '/tmp/a.mp4');
    expect(segment.duration, const Duration(milliseconds: 1500));
    expect(segment.thumbnailPath, '/tmp/a.jpg');
  });

  test('setBackground and mergeSegments send arguments', () async {
    final camera = BgCamera();
    await camera.setBackground(BackgroundType.image, path: '/tmp/bg.jpg');
    final merged = await camera.mergeSegments([
      const RecordedSegment(path: '/a.mp4', duration: Duration(seconds: 2)),
      const RecordedSegment(
        path: '/b.mp4',
        duration: Duration(seconds: 3),
      ).trimmed(
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 2500),
      ),
    ]);

    expect(calls[0].arguments, {
      'type': 'image',
      'path': '/tmp/bg.jpg',
      'blurStrength': 0.5,
    });
    expect(calls[1].arguments, {
      'segments': [
        {'path': '/a.mp4', 'startMs': 0, 'endMs': 2000},
        {'path': '/b.mp4', 'startMs': 250, 'endMs': 2500},
      ],
    });
    expect(merged, '/tmp/out.mp4');
  });

  test('supportedResolutions keeps known values in order', () async {
    expect(await BgCamera().supportedResolutions(), [
      VideoResolution.p720,
      VideoResolution.p1080,
    ]);
  });

  test('setZoom clamps the fraction', () async {
    await BgCamera().setZoom(1.7);
    expect(calls.single.arguments, {'fraction': 1.0});
  });

  test('transcribe parses captions and burnSubtitles sends them', () async {
    final camera = BgCamera();
    final captions = await camera.transcribe('/tmp/v.mp4', localeId: 'es-CO');

    expect(captions, [
      const Caption(
        start: Duration.zero,
        end: Duration(milliseconds: 1200),
        text: 'Hola a todos',
      ),
      const Caption(
        start: Duration(milliseconds: 1500),
        end: Duration(milliseconds: 2800),
        text: 'bienvenidos',
      ),
    ]);
    expect(calls.first.arguments, {'path': '/tmp/v.mp4', 'locale': 'es-CO'});

    final out = await camera.burnSubtitles('/tmp/v.mp4', [captions.first]);
    expect(out, '/tmp/subs.mp4');
    expect(calls.last.arguments, {
      'path': '/tmp/v.mp4',
      'captions': [
        {'startMs': 0, 'endMs': 1200, 'text': 'Hola a todos'},
      ],
    });
  });
}

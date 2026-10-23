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
          }
          return null;
        });
  });

  test('initialize returns preview info', () async {
    final info = await BgCamera().initialize(lens: CameraLens.back);

    expect(calls.single.arguments, {'lens': 'back'});
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
    final merged = await camera.mergeSegments(['/a.mp4', '/b.mp4']);

    expect(calls[0].arguments, {'type': 'image', 'path': '/tmp/bg.jpg'});
    expect(calls[1].arguments, {
      'paths': ['/a.mp4', '/b.mp4'],
    });
    expect(merged, '/tmp/out.mp4');
  });
}

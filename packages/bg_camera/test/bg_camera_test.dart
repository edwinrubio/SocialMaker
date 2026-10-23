import 'package:flutter_test/flutter_test.dart';
import 'package:bg_camera/bg_camera.dart';
import 'package:bg_camera/bg_camera_platform_interface.dart';
import 'package:bg_camera/bg_camera_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockBgCameraPlatform
    with MockPlatformInterfaceMixin
    implements BgCameraPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final BgCameraPlatform initialPlatform = BgCameraPlatform.instance;

  test('$MethodChannelBgCamera is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelBgCamera>());
  });

  test('getPlatformVersion', () async {
    BgCamera bgCameraPlugin = BgCamera();
    MockBgCameraPlatform fakePlatform = MockBgCameraPlatform();
    BgCameraPlatform.instance = fakePlatform;

    expect(await bgCameraPlugin.getPlatformVersion(), '42');
  });
}

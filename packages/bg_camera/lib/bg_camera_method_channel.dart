import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bg_camera_platform_interface.dart';

/// An implementation of [BgCameraPlatform] that uses method channels.
class MethodChannelBgCamera extends BgCameraPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('bg_camera');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'bg_camera_method_channel.dart';

abstract class BgCameraPlatform extends PlatformInterface {
  /// Constructs a BgCameraPlatform.
  BgCameraPlatform() : super(token: _token);

  static final Object _token = Object();

  static BgCameraPlatform _instance = MethodChannelBgCamera();

  /// The default instance of [BgCameraPlatform] to use.
  ///
  /// Defaults to [MethodChannelBgCamera].
  static BgCameraPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [BgCameraPlatform] when
  /// they register themselves.
  static set instance(BgCameraPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}

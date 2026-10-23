
import 'bg_camera_platform_interface.dart';

class BgCamera {
  Future<String?> getPlatformVersion() {
    return BgCameraPlatform.instance.getPlatformVersion();
  }
}

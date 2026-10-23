import 'package:shared_preferences/shared_preferences.dart';

/// Small persisted key/value settings, injectable for tests.
abstract class SettingsStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class PrefsSettingsStore implements SettingsStore {
  final _prefs = SharedPreferencesAsync();

  @override
  Future<String?> read(String key) => _prefs.getString(key);

  @override
  Future<void> write(String key, String value) => _prefs.setString(key, value);
}

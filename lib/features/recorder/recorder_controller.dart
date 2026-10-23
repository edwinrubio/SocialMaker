import 'dart:async';
import 'dart:io';

import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../settings/settings_store.dart';

/// State of a recording session: camera preview, the recorded fragments and
/// the selected background.
class RecorderController extends ChangeNotifier {
  RecorderController({
    BgCamera? camera,
    SettingsStore? settings,
    this.maxDuration = const Duration(minutes: 10),
  }) : camera = camera ?? BgCamera(),
       settings = settings ?? PrefsSettingsStore();

  static const resolutionKey = 'resolution';

  final BgCamera camera;
  final SettingsStore settings;
  final Duration maxDuration;

  CameraPreviewInfo? preview;
  String? error;
  BackgroundType backgroundType = BackgroundType.none;
  String? _backgroundPath;

  VideoResolution resolution = VideoResolution.p1080;
  List<VideoResolution> supportedResolutions = const [];

  double _lastZoom = 0;

  final List<RecordedSegment> _segments = [];
  List<RecordedSegment> get segments => List.unmodifiable(_segments);

  /// Fragment picked in the strip; the delete button removes it.
  int? selectedIndex;

  bool _recording = false;
  bool get isRecording => _recording;

  final Stopwatch _stopwatch = Stopwatch();
  Future<void>? _starting;
  Timer? _limitTimer;
  Timer? _ticker;

  Duration get recordedDuration =>
      _segments.fold(Duration.zero, (total, s) => total + s.duration);

  /// Recorded time plus the fragment currently being recorded.
  Duration get liveDuration =>
      recordedDuration + (_recording ? _stopwatch.elapsed : Duration.zero);

  Duration get currentSegmentDuration =>
      _recording ? _stopwatch.elapsed : Duration.zero;

  bool get canRecord =>
      preview != null && !_recording && recordedDuration < maxDuration;

  Future<void> initialize() async {
    error = null;
    if (!await camera.requestPermissions()) {
      error = 'Se necesita acceso a la cámara y al micrófono.';
      notifyListeners();
      return;
    }
    try {
      if (supportedResolutions.isEmpty) {
        supportedResolutions = await camera.supportedResolutions();
        resolution = _pickResolution(await settings.read(resolutionKey));
      }
      preview = await camera.initialize(resolution: resolution);
      if (backgroundType != BackgroundType.none) {
        await camera.setBackground(backgroundType, path: _backgroundPath);
      }
    } on PlatformException catch (e) {
      debugPrint('initialize failed: ${e.message}');
      error = 'No se pudo abrir la cámara o el micrófono.';
    }
    notifyListeners();
  }

  Future<void> startSegment() async {
    if (!canRecord) return;
    selectedIndex = null;
    _recording = true;
    _stopwatch
      ..reset()
      ..start();
    _limitTimer = Timer(maxDuration - recordedDuration, stopSegment);
    _ticker = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => notifyListeners(),
    );
    notifyListeners();
    _starting = camera.startSegment();
    try {
      await _starting;
    } on PlatformException catch (e) {
      _finishRecordingState();
      debugPrint('startSegment failed: ${e.message}');
      error = 'No se pudo iniciar la grabación. Intenta de nuevo.';
      notifyListeners();
    }
  }

  Future<void> stopSegment() async {
    if (!_recording) return;
    _finishRecordingState();
    notifyListeners();
    try {
      await _starting;
      _segments.add(await camera.stopSegment());
      error = null;
    } on PlatformException catch (e) {
      // Usually a release before the first frame arrived: nothing recorded.
      debugPrint('stopSegment failed: ${e.message}');
      error = e.message;
    }
    notifyListeners();
  }

  /// Selects the fragment at [index], or clears the selection if it was selected.
  void toggleSelection(int index) {
    selectedIndex = selectedIndex == index ? null : index;
    notifyListeners();
  }

  void removeSegmentAt(int index) {
    _deleteSegmentFiles(_segments.removeAt(index));
    final selected = selectedIndex;
    if (selected == index) {
      selectedIndex = null;
    } else if (selected != null && selected > index) {
      selectedIndex = selected - 1;
    }
    notifyListeners();
  }

  /// Removes the selected fragment, or the last one when none is selected.
  void removeSelectedOrLastSegment() {
    if (_segments.isEmpty) return;
    removeSegmentAt(selectedIndex ?? _segments.length - 1);
  }

  /// Deletes every fragment, e.g. after the final video was exported.
  void clearSegments() {
    _segments.forEach(_deleteSegmentFiles);
    _segments.clear();
    selectedIndex = null;
    notifyListeners();
  }

  /// Changes the output size. Fragments can only be merged at one size, so
  /// the existing ones are deleted; ask the user before calling this.
  Future<void> changeResolution(VideoResolution value) async {
    if (value == resolution || _recording) return;
    clearSegments();
    resolution = value;
    preview = null;
    notifyListeners();
    await settings.write(resolutionKey, value.name);
    await camera.dispose();
    await initialize();
  }

  /// Zoom while recording; [fraction] 0..1. Small changes are not sent.
  void setZoom(double fraction) {
    final value = fraction.clamp(0.0, 1.0);
    if (value != 0 && (value - _lastZoom).abs() < 0.01) return;
    if (value == 0 && _lastZoom == 0) return;
    _lastZoom = value;
    camera.setZoom(value);
  }

  Future<void> setBackground(BackgroundType type, {String? path}) async {
    try {
      await camera.setBackground(type, path: path);
      backgroundType = type;
      _backgroundPath = path;
      error = null;
    } on PlatformException catch (e) {
      error = e.message ?? 'No se pudo aplicar el fondo.';
    }
    notifyListeners();
  }

  Future<void> switchCamera() => camera.switchCamera();

  /// Merges the remaining fragments, in order, and returns the video path.
  Future<String> export() =>
      camera.mergeSegments([for (final s in _segments) s.path]);

  @override
  void dispose() {
    _finishRecordingState();
    camera.dispose();
    super.dispose();
  }

  void _finishRecordingState() {
    _recording = false;
    _stopwatch.stop();
    _limitTimer?.cancel();
    _ticker?.cancel();
  }

  /// The saved choice if this device supports it, else the best up to 1080p.
  VideoResolution _pickResolution(String? saved) {
    final supported = supportedResolutions.isEmpty
        ? const [VideoResolution.p720]
        : supportedResolutions;
    for (final candidate in supported) {
      if (candidate.name == saved) return candidate;
    }
    return supported.lastWhere(
      (r) => r.index <= VideoResolution.p1080.index,
      orElse: () => supported.first,
    );
  }

  static void _deleteSegmentFiles(RecordedSegment segment) {
    for (final path in [segment.path, ?segment.thumbnailPath]) {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    }
  }
}

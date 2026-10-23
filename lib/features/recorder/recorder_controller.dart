import 'dart:async';
import 'dart:io';

import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// State of a recording session: camera preview, the recorded fragments and
/// the selected background.
class RecorderController extends ChangeNotifier {
  RecorderController({
    BgCamera? camera,
    this.maxDuration = const Duration(seconds: 60),
  }) : camera = camera ?? BgCamera();

  final BgCamera camera;
  final Duration maxDuration;

  CameraPreviewInfo? preview;
  String? error;
  BackgroundType backgroundType = BackgroundType.none;

  final List<RecordedSegment> _segments = [];
  List<RecordedSegment> get segments => List.unmodifiable(_segments);

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
      preview = await camera.initialize();
    } on PlatformException catch (e) {
      error = e.message ?? 'No se pudo abrir la cámara.';
    }
    notifyListeners();
  }

  Future<void> startSegment() async {
    if (!canRecord) return;
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
      error = e.message;
    }
    notifyListeners();
  }

  void removeSegmentAt(int index) {
    _deleteSegmentFiles(_segments.removeAt(index));
    notifyListeners();
  }

  void removeLastSegment() {
    if (_segments.isNotEmpty) removeSegmentAt(_segments.length - 1);
  }

  /// Deletes every fragment, e.g. after the final video was exported.
  void clearSegments() {
    _segments.forEach(_deleteSegmentFiles);
    _segments.clear();
    notifyListeners();
  }

  Future<void> setBackground(BackgroundType type, {String? path}) async {
    try {
      await camera.setBackground(type, path: path);
      backgroundType = type;
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

  static void _deleteSegmentFiles(RecordedSegment segment) {
    for (final path in [segment.path, ?segment.thumbnailPath]) {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    }
  }
}

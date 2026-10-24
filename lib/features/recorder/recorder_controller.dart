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
  static const blurStrengthKey = 'blur-strength';
  static const pipOriginKey = 'pip-origin';
  static const frameRateKey = 'frame-rate';

  final BgCamera camera;
  final SettingsStore settings;
  final Duration maxDuration;

  CameraPreviewInfo? preview;
  String? error;
  BackgroundType backgroundType = BackgroundType.none;
  String? _backgroundPath;

  /// 0 (subtle) to 1 (strong), for [BackgroundType.blur].
  double blurStrength = 0.5;

  /// Both cameras at once: the other one in a window at [pipOrigin]
  /// (top-left corner, fractions of the frame).
  bool dualSupported = false;
  bool dualEnabled = false;

  /// Sizes the device can record with both cameras (4K only on some).
  List<VideoResolution> dualResolutions = const [];
  Offset pipOrigin = defaultPipOrigin;

  VideoResolution resolution = VideoResolution.p1080;
  List<VideoResolution> supportedResolutions = const [];

  VideoFrameRate frameRate = VideoFrameRate.fps30;
  Map<VideoResolution, List<VideoFrameRate>> supportedFrameRates = const {};

  /// Rates available at [value] (30 fps when the device didn't say).
  List<VideoFrameRate> frameRatesFor(VideoResolution value) =>
      supportedFrameRates[value] ?? const [VideoFrameRate.fps30];

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
      _segments.fold(Duration.zero, (total, s) => total + s.length);

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
        supportedFrameRates = {
          for (final r in supportedResolutions)
            r: await camera.supportedFrameRates(r),
        };
        frameRate = _pickFrameRate(await settings.read(frameRateKey));
        blurStrength =
            double.tryParse(await settings.read(blurStrengthKey) ?? '') ??
            blurStrength;
        dualSupported = await camera.dualCameraSupported();
        dualResolutions = await camera.dualCameraResolutions();
        final saved = (await settings.read(pipOriginKey))?.split(',');
        final x = double.tryParse(saved?.first ?? '');
        final y = double.tryParse(saved?.last ?? '');
        if (x != null && y != null) pipOrigin = pipRectAt(Offset(x, y)).topLeft;
      }
      preview = await camera.initialize(
        resolution: resolution,
        frameRate: frameRate,
      );
      if (dualEnabled) {
        await camera.setPictureInPicture(pipRectAt(pipOrigin));
        await camera.setDualCamera(true);
      }
      if (backgroundType != BackgroundType.none) {
        await camera.setBackground(
          backgroundType,
          path: _backgroundPath,
          blurStrength: blurStrength,
        );
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

  /// Keeps only [start]..[end] of fragment [index] in the final video.
  void trimSegmentAt(int index, Duration start, Duration end) {
    _segments[index] = _segments[index].trimmed(start, end);
    notifyListeners();
  }

  /// Removes the selected fragment, or the last one when none is selected.
  void removeSelectedOrLastSegment() {
    if (_segments.isEmpty) return;
    removeSegmentAt(selectedIndex ?? _segments.length - 1);
  }

  /// Deletes every fragment: after the final video was exported, or when the
  /// user starts over.
  void clearSegments() {
    _segments.forEach(_deleteSegmentFiles);
    _segments.clear();
    selectedIndex = null;
    notifyListeners();
  }

  /// Changes the output size (and the frame rate, if the current one isn't
  /// available at it). Fragments can only be merged in one format, so the
  /// existing ones are deleted; ask the user before calling this.
  Future<void> changeResolution(VideoResolution value) async {
    if (value == resolution || _recording) return;
    if (dualEnabled && !dualResolutions.contains(value)) return;
    resolution = value;
    await settings.write(resolutionKey, value.name);
    if (!frameRatesFor(value).contains(frameRate)) {
      frameRate = _pickFrameRate(frameRate.name);
      await settings.write(frameRateKey, frameRate.name);
    }
    await _reopen();
  }

  /// Changes the frames per second; deletes the fragments like
  /// [changeResolution].
  Future<void> changeFrameRate(VideoFrameRate value) async {
    if (value == frameRate || _recording) return;
    if (!frameRatesFor(resolution).contains(value)) return;
    frameRate = value;
    await settings.write(frameRateKey, value.name);
    await _reopen();
  }

  Future<void> _reopen() async {
    clearSegments();
    preview = null;
    notifyListeners();
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
      await camera.setBackground(type, path: path, blurStrength: blurStrength);
      backgroundType = type;
      _backgroundPath = path;
      error = null;
    } on PlatformException catch (e) {
      error = e.message ?? 'No se pudo aplicar el fondo.';
    }
    notifyListeners();
  }

  /// Applies a new blur level live while the slider moves (skipping tiny
  /// steps); with [done], also remembers it.
  Future<void> setBlurStrength(double value, {bool done = false}) async {
    final changed = (value - blurStrength).abs() >= 0.02;
    if (changed || done) {
      blurStrength = value;
      if (backgroundType == BackgroundType.blur) {
        await camera.setBackground(
          BackgroundType.blur,
          blurStrength: blurStrength,
        );
      }
    }
    if (done) await settings.write(blurStrengthKey, value.toString());
  }

  /// Allowed while recording; in dual mode it swaps the two cameras.
  Future<void> switchCamera() => camera.switchCamera();

  /// Turns recording with both cameras on or off (not while recording).
  Future<void> toggleDual() async {
    if (_recording || preview == null) return;
    if (!dualSupported) {
      error = 'Este teléfono no permite usar las dos cámaras a la vez.';
      notifyListeners();
      return;
    }
    final enable = !dualEnabled;
    if (enable && !dualResolutions.contains(resolution)) {
      error =
          'Este teléfono no permite grabar en ${resolution.label} con las dos '
          'cámaras. Baja la resolución en Configuración.';
      notifyListeners();
      return;
    }
    try {
      if (enable) await camera.setPictureInPicture(pipRectAt(pipOrigin));
      await camera.setDualCamera(enable);
      dualEnabled = enable;
      error = null;
    } on PlatformException catch (e) {
      debugPrint('setDualCamera failed: ${e.message}');
      error = 'No se pudieron usar las dos cámaras a la vez.';
    }
    notifyListeners();
  }

  /// Moves the second camera's window (live while dragging, also while
  /// recording); with [done], remembers where it was left.
  Future<void> setPipOrigin(Offset origin, {bool done = false}) async {
    final rect = pipRectAt(origin);
    pipOrigin = rect.topLeft;
    notifyListeners();
    await camera.setPictureInPicture(rect);
    if (done) {
      await settings.write(pipOriginKey, '${pipOrigin.dx},${pipOrigin.dy}');
    }
  }

  /// Merges the remaining fragments, in order, and returns the video path.
  Future<String> export() => camera.mergeSegments(_segments);

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

  /// [saved] if available at the current resolution, else the highest
  /// rate up to it (30 fps when nothing was saved).
  VideoFrameRate _pickFrameRate(String? saved) {
    final available = frameRatesFor(resolution);
    final wanted = VideoFrameRate.values.firstWhere(
      (r) => r.name == saved,
      orElse: () => VideoFrameRate.fps30,
    );
    if (available.contains(wanted)) return wanted;
    return available.lastWhere(
      (r) => r.fps <= wanted.fps,
      orElse: () => available.first,
    );
  }

  static void _deleteSegmentFiles(RecordedSegment segment) {
    for (final path in [segment.path, ?segment.thumbnailPath]) {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    }
  }
}

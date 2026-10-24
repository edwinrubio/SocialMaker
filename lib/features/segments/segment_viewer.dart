import 'dart:io';

import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart' hide Caption;

import '../../brand.dart';

/// What the user decided in the fragment viewer.
sealed class SegmentDecision {
  const SegmentDecision();
}

final class DeleteSegment extends SegmentDecision {
  const DeleteSegment();
}

/// Keep only [start]..[end] of the fragment.
final class TrimSegment extends SegmentDecision {
  const TrimSegment(this.start, this.end);

  final Duration start;
  final Duration end;
}

/// Plays fragment [index] full screen so the user can keep, trim or delete
/// it. Resolves to null when it stays as it was.
Future<SegmentDecision?> showSegmentViewer(
  BuildContext context,
  RecordedSegment segment,
  int index,
) {
  return Navigator.of(context).push<SegmentDecision>(
    PageRouteBuilder(
      opaque: true,
      fullscreenDialog: true,
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (_, _, _) => _SegmentViewer(segment: segment, index: index),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _SegmentViewer extends StatefulWidget {
  const _SegmentViewer({required this.segment, required this.index});

  final RecordedSegment segment;
  final int index;

  @override
  State<_SegmentViewer> createState() => _SegmentViewerState();
}

class _SegmentViewerState extends State<_SegmentViewer> {
  late final VideoPlayerController _player = VideoPlayerController.file(
    File(widget.segment.path),
  );
  bool _ready = false;

  /// Slider position while the user drags it (null otherwise).
  double? _scrubMs;
  bool _resumeAfterScrub = false;

  /// Part of the file that is kept, in milliseconds.
  late double _startMs = widget.segment.start.inMilliseconds.toDouble();
  late double _endMs = widget.segment.end.inMilliseconds.toDouble();

  /// Trim handles while editing (null when not trimming).
  RangeValues? _trim;

  /// Shortest fragment a trim can leave.
  static const _minLengthMs = 500.0;

  double get _fileMs => widget.segment.duration.inMilliseconds.toDouble();
  double get _playStartMs => _trim?.start ?? _startMs;
  double get _playEndMs => _trim?.end ?? _endMs;

  @override
  void initState() {
    super.initState();
    _player.addListener(_onTick);
    _player.initialize().then((_) async {
      await _player.setLooping(true);
      if (_startMs > 0) await _seekMs(_startMs);
      await _player.play();
      if (mounted) setState(() => _ready = true);
    });
  }

  void _onTick() {
    if (!mounted || _scrubMs != null) return;
    // Loop inside the kept part: the player itself loops over the whole file.
    final value = _player.value;
    final ms = value.position.inMilliseconds;
    if (value.isPlaying && (ms >= _playEndMs || ms < _playStartMs - 100)) {
      _seekMs(_playStartMs);
    }
    setState(() {});
  }

  Future<void> _seekMs(double ms) =>
      _player.seekTo(Duration(milliseconds: ms.round()));

  @override
  void dispose() {
    _player.removeListener(_onTick);
    _player.dispose();
    super.dispose();
  }

  void _togglePlay() {
    setState(() {
      _player.value.isPlaying ? _player.pause() : _player.play();
    });
  }

  static String _seconds(Duration d) =>
      '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';

  /// m:ss.d, e.g. 0:03.4.
  static String _clock(Duration d) {
    final seconds = (d.inMilliseconds % 60000 / 1000).toStringAsFixed(1);
    return '${d.inMinutes}:${seconds.padLeft(4, '0')}';
  }

  void _scrubStart(double ms) {
    _resumeAfterScrub = _player.value.isPlaying;
    _player.pause();
    setState(() => _scrubMs = ms);
  }

  /// Seeks while dragging so the frame under the finger shows.
  void _scrub(double ms) {
    setState(() => _scrubMs = ms);
    _player.seekTo(Duration(milliseconds: ms.round()));
  }

  Future<void> _scrubEnd(double ms) async {
    await _player.seekTo(Duration(milliseconds: ms.round()));
    if (_resumeAfterScrub) await _player.play();
    if (mounted) setState(() => _scrubMs = null);
  }

  /// Leaves the viewer keeping the fragment, with its trim if it changed.
  void _keep() {
    final start = Duration(milliseconds: _startMs.round());
    final end = Duration(milliseconds: _endMs.round());
    final changed = start != widget.segment.start || end != widget.segment.end;
    Navigator.pop(context, changed ? TrimSegment(start, end) : null);
  }

  void _startTrimming() {
    setState(() => _trim = RangeValues(_startMs, _endMs));
  }

  void _cancelTrimming() {
    setState(() => _trim = null);
    _seekMs(_startMs);
  }

  void _applyTrim() {
    final trim = _trim!;
    setState(() {
      _startMs = trim.start;
      _endMs = trim.end;
      _trim = null;
    });
    _seekMs(_startMs);
    _player.play();
  }

  /// Shows the frame under the handle being dragged.
  void _moveTrim(RangeValues values) {
    final previous = _trim!;
    final gap = _minLengthMs < _fileMs ? _minLengthMs : _fileMs / 2;
    var start = values.start;
    var end = values.end;
    if (end - start < gap) {
      if (start != previous.start) {
        start = end - gap;
      } else {
        end = start + gap;
      }
    }
    final next = RangeValues(start.clamp(0, _fileMs), end.clamp(0, _fileMs));
    _player.pause();
    setState(() => _trim = next);
    _seekMs(next.start != previous.start ? next.start : next.end);
  }

  Future<void> _trimMoved(RangeValues _) async {
    await _seekMs(_trim!.start);
    await _player.play();
  }

  Widget _buildTrimmer() {
    final trim = _trim!;
    const labelStyle = TextStyle(
      fontSize: 13,
      color: Colors.white,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    Duration ms(double value) => Duration(milliseconds: value.round());
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          const Text(
            'Arrastra los extremos para quitar el inicio o el final.',
            style: TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              rangeThumbShape: const RoundRangeSliderThumbShape(
                enabledThumbRadius: 11,
              ),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
            ),
            child: RangeSlider(
              key: const Key('segment-trimmer'),
              values: trim,
              max: _fileMs,
              activeColor: Brand.pink,
              inactiveColor: Colors.white24,
              semanticFormatterCallback: (value) => _clock(ms(value)),
              onChanged: _moveTrim,
              onChangeEnd: _trimMoved,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text('Inicio ${_clock(ms(trim.start))}', style: labelStyle),
                Expanded(
                  child: Text(
                    'Queda ${_seconds(ms(trim.end - trim.start))}',
                    style: labelStyle.copyWith(fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                ),
                Text('Fin ${_clock(ms(trim.end))}', style: labelStyle),
              ],
            ),
          ),
          if (trim.start > 0 || trim.end < _fileMs)
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
              onPressed: () => setState(() => _trim = RangeValues(0, _fileMs)),
              icon: const Icon(Icons.restore, size: 18),
              label: const Text('Usar el fragmento completo'),
            )
          else
            const SizedBox(height: 48),
        ],
      ),
    );
  }

  Widget _buildScrubber() {
    // The scrubber covers only the kept part of the fragment.
    final min = _startMs;
    final max = _endMs > min ? _endMs : min + 1;
    final position =
        (_scrubMs ?? _player.value.position.inMilliseconds.toDouble()).clamp(
          min,
          max,
        );
    const labelStyle = TextStyle(
      fontSize: 12,
      color: Colors.white70,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Text(
            _clock(Duration(milliseconds: position.round())),
            style: labelStyle,
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
              ),
              child: Slider(
                key: const Key('segment-scrubber'),
                value: position,
                min: min,
                max: max,
                activeColor: Brand.pink,
                inactiveColor: Colors.white24,
                semanticFormatterCallback: (ms) =>
                    _clock(Duration(milliseconds: ms.round())),
                onChangeStart: _scrubStart,
                onChanged: _scrub,
                onChangeEnd: _scrubEnd,
              ),
            ),
          ),
          Text(_clock(Duration(milliseconds: max.round())), style: labelStyle),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trimming = _trim != null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            key: const Key('segment-viewer-video'),
            onTap: _ready ? _togglePlay : null,
            child: Center(
              child: _ready
                  ? AspectRatio(
                      aspectRatio: _player.value.aspectRatio,
                      child: VideoPlayer(_player),
                    )
                  : const CircularProgressIndicator(),
            ),
          ),
          if (_ready &&
              !_player.value.isPlaying &&
              _scrubMs == null &&
              !trimming)
            const IgnorePointer(
              child: Center(
                child: Icon(
                  Icons.play_arrow_rounded,
                  size: 96,
                  color: Colors.white70,
                ),
              ),
            ),
          // Scrims keep the header and controls readable over bright video.
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0, 0.15, 0.7, 1],
                  colors: [
                    Colors.black54,
                    Colors.transparent,
                    Colors.transparent,
                    Colors.black87,
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Cerrar',
                        onPressed: trimming ? _cancelTrimming : _keep,
                        icon: const Icon(Icons.close, size: 28),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          trimming
                              ? 'Recortar fragmento ${widget.index + 1}'
                              : 'Fragmento ${widget.index + 1} · '
                                    '${_seconds(Duration(milliseconds: (_endMs - _startMs).round()))}',
                          style: Theme.of(context).textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!trimming && _ready)
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            backgroundColor: Colors.black38,
                          ),
                          onPressed: _startTrimming,
                          icon: const Icon(Icons.content_cut, size: 18),
                          label: const Text('Recortar'),
                        ),
                    ],
                  ),
                ),
                const Spacer(),
                if (_ready) trimming ? _buildTrimmer() : _buildScrubber(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white38),
                            minimumSize: const Size.fromHeight(52),
                          ),
                          onPressed: trimming
                              ? _cancelTrimming
                              : () => Navigator.pop(
                                  context,
                                  const DeleteSegment(),
                                ),
                          icon: Icon(
                            trimming ? Icons.close : Icons.delete_outline,
                          ),
                          label: Text(trimming ? 'Cancelar' : 'Borrar'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Brand.pink,
                            minimumSize: const Size.fromHeight(52),
                          ),
                          onPressed: trimming ? _applyTrim : _keep,
                          icon: const Icon(Icons.check),
                          label: Text(trimming ? 'Aplicar' : 'Conservar'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

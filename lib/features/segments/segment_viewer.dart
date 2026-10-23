import 'dart:io';

import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart' hide Caption;

import '../../brand.dart';

/// Plays fragment [index] full screen so the user can decide whether to keep
/// it. Resolves to true when they choose to delete it.
Future<bool> showSegmentViewer(
  BuildContext context,
  RecordedSegment segment,
  int index,
) async {
  final delete = await Navigator.of(context).push<bool>(
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
  return delete ?? false;
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

  @override
  void initState() {
    super.initState();
    _player.addListener(_onTick);
    _player.initialize().then((_) async {
      await _player.setLooping(true);
      await _player.play();
      if (mounted) setState(() => _ready = true);
    });
  }

  void _onTick() {
    if (mounted && _scrubMs == null) setState(() {});
  }

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

  Widget _buildScrubber() {
    final total = _player.value.duration.inMilliseconds.toDouble();
    final position =
        (_scrubMs ?? _player.value.position.inMilliseconds.toDouble()).clamp(
          0.0,
          total > 0 ? total : 1.0,
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
                max: total > 0 ? total : 1,
                activeColor: Brand.pink,
                inactiveColor: Colors.white24,
                semanticFormatterCallback: (ms) =>
                    _clock(Duration(milliseconds: ms.round())),
                onChangeStart: total > 0 ? _scrubStart : null,
                onChanged: total > 0 ? _scrub : null,
                onChangeEnd: total > 0 ? _scrubEnd : null,
              ),
            ),
          ),
          Text(_clock(_player.value.duration), style: labelStyle),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
          if (_ready && !_player.value.isPlaying && _scrubMs == null)
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
                        onPressed: () => Navigator.pop(context, false),
                        icon: const Icon(Icons.close, size: 28),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Fragmento ${widget.index + 1} · '
                        '${_seconds(widget.segment.duration)}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (_ready) _buildScrubber(),
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
                          onPressed: () => Navigator.pop(context, true),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Borrar'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Brand.pink,
                            minimumSize: const Size.fromHeight(52),
                          ),
                          onPressed: () => Navigator.pop(context, false),
                          icon: const Icon(Icons.check),
                          label: const Text('Conservar'),
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

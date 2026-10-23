import 'dart:io';

import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart' hide Caption;

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

  @override
  void initState() {
    super.initState();
    _player.initialize().then((_) async {
      await _player.setLooping(true);
      await _player.play();
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
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
          if (_ready && !_player.value.isPlaying)
            const IgnorePointer(
              child: Center(
                child: Icon(
                  Icons.play_arrow_rounded,
                  size: 96,
                  color: Colors.white70,
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
                if (_ready)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: VideoProgressIndicator(
                      _player,
                      allowScrubbing: true,
                      colors: const VideoProgressColors(
                        playedColor: Color(0xFFFE2C55),
                        bufferedColor: Colors.white24,
                        backgroundColor: Colors.white12,
                      ),
                    ),
                  ),
                const Spacer(),
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
                          label: const Text('Borrar fragmento'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFFE2C55),
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

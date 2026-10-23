import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../export/export_screen.dart';
import '../recorder/recorder_controller.dart';

/// Lists the recorded fragments: tap one to play it, delete the ones that
/// should not be in the final video, then export.
class SegmentsReviewScreen extends StatefulWidget {
  const SegmentsReviewScreen({super.key, required this.controller});

  final RecorderController controller;

  @override
  State<SegmentsReviewScreen> createState() => _SegmentsReviewScreenState();
}

class _SegmentsReviewScreenState extends State<SegmentsReviewScreen> {
  int _selected = 0;
  VideoPlayerController? _player;

  RecorderController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _play(0);
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _play(int index) async {
    final old = _player;
    final segments = _controller.segments;
    if (segments.isEmpty) {
      setState(() => _player = null);
      await old?.dispose();
      return;
    }
    final player = VideoPlayerController.file(File(segments[index].path));
    setState(() {
      _selected = index;
      _player = player;
    });
    await old?.dispose();
    await player.initialize();
    await player.setLooping(true);
    await player.play();
    if (mounted) setState(() {});
  }

  void _delete(int index) {
    _controller.removeSegmentAt(index);
    if (_controller.segments.isEmpty) {
      Navigator.pop(context);
      return;
    }
    final next = index < _selected || _selected >= _controller.segments.length
        ? (_selected - 1).clamp(0, _controller.segments.length - 1)
        : _selected;
    _play(next);
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Fragmentos'),
      ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final segments = _controller.segments;
          return Column(
            children: [
              Expanded(
                child: Center(
                  child: player != null && player.value.isInitialized
                      ? AspectRatio(
                          aspectRatio: player.value.aspectRatio,
                          child: VideoPlayer(player),
                        )
                      : const CircularProgressIndicator(),
                ),
              ),
              SizedBox(
                height: 112,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(12),
                  itemCount: segments.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) => _SegmentTile(
                    index: index,
                    duration: segments[index].duration,
                    selected: index == _selected,
                    onTap: () => _play(index),
                    onDelete: () => _delete(index),
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFE2C55),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: segments.isEmpty
                          ? null
                          : () {
                              _player?.pause();
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      ExportScreen(controller: _controller),
                                ),
                              );
                            },
                      icon: const Icon(Icons.movie_creation_outlined),
                      label: Text(
                        'Exportar ${segments.length} fragmento${segments.length == 1 ? '' : 's'}',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SegmentTile extends StatelessWidget {
  const _SegmentTile({
    required this.index,
    required this.duration,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  final int index;
  final Duration duration;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          color: selected ? const Color(0x33FE2C55) : Colors.white10,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: selected ? const Color(0xFFFE2C55) : Colors.transparent,
              width: 2,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: SizedBox(
              width: 72,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${index + 1}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(
                    '${(duration.inMilliseconds / 1000).toStringAsFixed(1)} s',
                    style: const TextStyle(color: Colors.white60),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: -8,
          right: -8,
          child: IconButton.filled(
            tooltip: 'Borrar fragmento ${index + 1}',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            style: IconButton.styleFrom(backgroundColor: Colors.white24),
            onPressed: onDelete,
            icon: const Icon(Icons.close),
          ),
        ),
      ],
    );
  }
}

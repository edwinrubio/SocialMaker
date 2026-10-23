import 'dart:io';

import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Plays one fragment. Resolves to true when the user chose to delete it.
Future<bool> showSegmentPreview(
  BuildContext context, {
  required RecordedSegment segment,
  required int index,
}) async {
  final delete = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF161616),
    showDragHandle: true,
    builder: (_) => _SegmentPreviewSheet(segment: segment, index: index),
  );
  return delete ?? false;
}

class _SegmentPreviewSheet extends StatefulWidget {
  const _SegmentPreviewSheet({required this.segment, required this.index});

  final RecordedSegment segment;
  final int index;

  @override
  State<_SegmentPreviewSheet> createState() => _SegmentPreviewSheetState();
}

class _SegmentPreviewSheetState extends State<_SegmentPreviewSheet> {
  late final VideoPlayerController _player = VideoPlayerController.file(
    File(widget.segment.path),
  );

  @override
  void initState() {
    super.initState();
    _player.initialize().then((_) {
      if (!mounted) return;
      _player
        ..setLooping(true)
        ..play();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = widget.segment.duration.inMilliseconds / 1000;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Fragmento ${widget.index + 1} · ${seconds.toStringAsFixed(1)} s',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.55,
              ),
              child: AspectRatio(
                aspectRatio: _player.value.isInitialized
                    ? _player.value.aspectRatio
                    : 9 / 16,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _player.value.isInitialized
                      ? VideoPlayer(_player)
                      : const ColoredBox(
                          color: Colors.black,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Conservar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(context, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFE2C55),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Eliminar'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

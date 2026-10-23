import 'dart:io';

import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/material.dart';

/// Thumbnails of the recorded fragments, shown under the camera preview.
class SegmentStrip extends StatelessWidget {
  const SegmentStrip({super.key, required this.segments, required this.onTap});

  final List<RecordedSegment> segments;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 76,
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(8),
        itemCount: segments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) => _Thumbnail(
          segment: segments[index],
          label: 'Fragmento ${index + 1}',
          onTap: () => onTap(index),
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.segment,
    required this.label,
    required this.onTap,
  });

  final RecordedSegment segment;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final thumbnail = segment.thumbnailPath;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 45,
            height: 60,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (thumbnail != null)
                  Image.file(File(thumbnail), fit: BoxFit.cover)
                else
                  const ColoredBox(color: Colors.white24),
                const Center(
                  child: Icon(
                    Icons.play_circle_outline,
                    color: Colors.white,
                    size: 22,
                    shadows: [Shadow(blurRadius: 4)],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

/// Progress bar split into the recorded fragments, plus the one in progress.
class SegmentBar extends StatelessWidget {
  const SegmentBar({
    super.key,
    required this.segments,
    required this.current,
    required this.max,
  });

  final List<Duration> segments;
  final Duration current;
  final Duration max;

  @override
  Widget build(BuildContext context) {
    const gap = 3.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: LayoutBuilder(
          builder: (context, constraints) {
            double widthOf(Duration d) =>
                constraints.maxWidth * d.inMicroseconds / max.inMicroseconds;
            return Stack(
              children: [
                Container(color: Colors.white24),
                Row(
                  children: [
                    for (final segment in segments) ...[
                      Container(
                        width: (widthOf(segment) - gap).clamp(
                          1.0,
                          double.infinity,
                        ),
                        color: const Color(0xFFFE2C55),
                      ),
                      Container(width: gap, color: Colors.white),
                    ],
                    if (current > Duration.zero)
                      Container(
                        width: widthOf(current),
                        color: const Color(0xFFFE2C55),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

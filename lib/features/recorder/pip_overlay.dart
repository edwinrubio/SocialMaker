import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/material.dart';

/// Touch target over the second camera's window, which the native renderer
/// draws into the preview (and the recording). Tap swaps the cameras; drag
/// moves it and it snaps to the nearest corner on release.
///
/// The preview fills the screen like `BoxFit.cover` over a frame of
/// [frameSize], so the window's frame rect is mapped the same way.
class PipOverlay extends StatefulWidget {
  const PipOverlay({
    super.key,
    required this.frameSize,
    required this.corner,
    required this.onCorner,
    required this.onSwap,
  });

  final Size frameSize;
  final PipCorner corner;
  final ValueChanged<PipCorner> onCorner;
  final VoidCallback onSwap;

  @override
  State<PipOverlay> createState() => _PipOverlayState();
}

class _PipOverlayState extends State<PipOverlay> {
  Offset? _drag;

  /// [rect] (fractions of the frame) in screen coordinates.
  Rect _toScreen(Rect rect, Size screen) {
    final frame = widget.frameSize;
    final scale = (screen.width / frame.width) > (screen.height / frame.height)
        ? screen.width / frame.width
        : screen.height / frame.height;
    final dx = (screen.width - frame.width * scale) / 2;
    final dy = (screen.height - frame.height * scale) / 2;
    return Rect.fromLTWH(
      dx + rect.left * frame.width * scale,
      dy + rect.top * frame.height * scale,
      rect.width * frame.width * scale,
      rect.height * frame.height * scale,
    );
  }

  void _end(Size screen, Rect home) {
    final center = home.center + (_drag ?? Offset.zero);
    final left = center.dx < screen.width / 2;
    final top = center.dy < screen.height / 2;
    setState(() => _drag = null);
    widget.onCorner(switch ((top, left)) {
      (true, true) => PipCorner.topLeft,
      (true, false) => PipCorner.topRight,
      (false, true) => PipCorner.bottomLeft,
      (false, false) => PipCorner.bottomRight,
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screen = constraints.biggest;
        final home = _toScreen(pipRectFor(widget.corner), screen);
        final rect = home.shift(_drag ?? Offset.zero);
        final radius = BorderRadius.circular(rect.width * 0.1);
        return Stack(
          children: [
            Positioned.fromRect(
              rect: rect,
              child: Semantics(
                button: true,
                label:
                    'Segunda cámara: toca para intercambiar, '
                    'arrastra para moverla a otra esquina',
                child: GestureDetector(
                  key: const Key('pip-window'),
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onSwap,
                  onPanStart: (_) => setState(() => _drag = Offset.zero),
                  onPanUpdate: (d) =>
                      setState(() => _drag = (_drag ?? Offset.zero) + d.delta),
                  onPanEnd: (_) => _end(screen, home),
                  onPanCancel: () => setState(() => _drag = null),
                  // While dragging, an outline follows the finger; the
                  // camera window itself moves once it lands in a corner.
                  child: _drag == null
                      ? const SizedBox.expand()
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: radius,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

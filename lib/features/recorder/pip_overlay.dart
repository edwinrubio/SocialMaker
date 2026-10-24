import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/material.dart';

/// Touch target over the second camera's window, which the native renderer
/// draws into the preview (and the recording). Tap swaps the cameras; drag
/// moves the window itself, live, and it stays where it is released.
///
/// The preview fills the screen like `BoxFit.cover` over a frame of
/// [frameSize], so frame fractions are mapped the same way.
class PipOverlay extends StatefulWidget {
  const PipOverlay({
    super.key,
    required this.frameSize,
    required this.origin,
    required this.onMove,
    required this.onSwap,
  });

  final Size frameSize;

  /// Window's top-left corner, in fractions of the frame.
  final Offset origin;

  /// Called while dragging, and with `done` on release.
  final Future<void> Function(Offset origin, {bool done}) onMove;
  final VoidCallback onSwap;

  @override
  State<PipOverlay> createState() => _PipOverlayState();
}

class _PipOverlayState extends State<PipOverlay> {
  static const _margin = 8.0;

  /// Origin while dragging (ahead of the controller's, which follows).
  Offset? _dragOrigin;

  /// Screen points per frame unit, and where the frame's (0, 0) lands.
  ({double scale, Offset offset}) _cover(Size screen) {
    final frame = widget.frameSize;
    final scale = (screen.width / frame.width) > (screen.height / frame.height)
        ? screen.width / frame.width
        : screen.height / frame.height;
    return (
      scale: scale,
      offset: Offset(
        (screen.width - frame.width * scale) / 2,
        (screen.height - frame.height * scale) / 2,
      ),
    );
  }

  Rect _toScreen(Rect rect, Size screen) {
    final (:scale, :offset) = _cover(screen);
    final frame = widget.frameSize;
    return Rect.fromLTWH(
      offset.dx + rect.left * frame.width * scale,
      offset.dy + rect.top * frame.height * scale,
      rect.width * frame.width * scale,
      rect.height * frame.height * scale,
    );
  }

  /// Moves the window by [delta] screen points, kept on the visible screen.
  void _drag(Offset delta, Size screen) {
    final (:scale, :offset) = _cover(screen);
    final frame = widget.frameSize;
    final current = _toScreen(pipRectAt(_dragOrigin ?? widget.origin), screen);
    final left = (current.left + delta.dx).clamp(
      _margin,
      screen.width - current.width - _margin,
    );
    final top = (current.top + delta.dy).clamp(
      _margin,
      screen.height - current.height - _margin,
    );
    final origin = Offset(
      (left - offset.dx) / (frame.width * scale),
      (top - offset.dy) / (frame.height * scale),
    );
    setState(() => _dragOrigin = origin);
    widget.onMove(origin);
  }

  void _release() {
    final origin = _dragOrigin;
    setState(() => _dragOrigin = null);
    if (origin != null) widget.onMove(origin, done: true);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screen = constraints.biggest;
        final rect = _toScreen(pipRectAt(_dragOrigin ?? widget.origin), screen);
        return Stack(
          children: [
            Positioned.fromRect(
              rect: rect,
              child: Semantics(
                button: true,
                label:
                    'Segunda cámara: toca para intercambiar, '
                    'arrástrala para moverla',
                child: GestureDetector(
                  key: const Key('pip-window'),
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onSwap,
                  onPanUpdate: (d) => _drag(d.delta, screen),
                  onPanEnd: (_) => _release(),
                  onPanCancel: _release,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

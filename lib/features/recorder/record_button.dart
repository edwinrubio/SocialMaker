import 'package:flutter/material.dart';

/// Hold to record, release to stop; while holding, sliding the finger up
/// zooms in proportionally (half the screen height is full zoom). Uses raw
/// pointer events so recording starts immediately instead of after the
/// long-press delay.
class RecordButton extends StatefulWidget {
  const RecordButton({
    super.key,
    required this.recording,
    required this.enabled,
    required this.onStart,
    required this.onStop,
    required this.onZoom,
  });

  final bool recording;
  final bool enabled;
  final VoidCallback onStart;
  final VoidCallback onStop;

  /// 0 (no zoom) to 1 (full zoom); called with 0 when released.
  final ValueChanged<double> onZoom;

  @override
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton> {
  double? _startY;

  void _down(PointerDownEvent event) {
    _startY = event.position.dy;
    widget.onStart();
  }

  void _move(PointerMoveEvent event) {
    final startY = _startY;
    if (startY == null) return;
    final travel = MediaQuery.sizeOf(context).height * 0.5;
    widget.onZoom(((startY - event.position.dy) / travel).clamp(0.0, 1.0));
  }

  void _end() {
    if (_startY != null) widget.onZoom(0);
    _startY = null;
    widget.onStop();
  }

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFFE2C55);
    final recording = widget.recording;
    final enabled = widget.enabled;
    return Semantics(
      button: true,
      label:
          'Mantén presionado para grabar; desliza hacia arriba para hacer zoom',
      child: Listener(
        onPointerDown: enabled ? _down : null,
        onPointerMove: _move,
        onPointerUp: (_) => _end(),
        onPointerCancel: (_) => _end(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: recording ? 104 : 84,
          height: recording ? 104 : 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: red.withValues(alpha: enabled || recording ? 0.6 : 0.25),
              width: recording ? 10 : 6,
            ),
          ),
          padding: const EdgeInsets.all(6),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: enabled || recording ? red : red.withValues(alpha: 0.4),
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

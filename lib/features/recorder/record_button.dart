import 'package:flutter/material.dart';

/// Hold to record, release to stop. Uses raw pointer events so recording
/// starts immediately instead of after the long-press delay.
class RecordButton extends StatelessWidget {
  const RecordButton({
    super.key,
    required this.recording,
    required this.enabled,
    required this.onStart,
    required this.onStop,
  });

  final bool recording;
  final bool enabled;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFFE2C55);
    return Semantics(
      button: true,
      label: 'Mantén presionado para grabar',
      child: Listener(
        onPointerDown: enabled ? (_) => onStart() : null,
        onPointerUp: (_) => onStop(),
        onPointerCancel: (_) => onStop(),
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

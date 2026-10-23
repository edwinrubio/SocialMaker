import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Tap to start recording and tap again to stop, or hold to record and
/// release to stop; while holding, sliding the finger up zooms in
/// proportionally (half the screen height is full zoom). Recording starts on
/// touch down either way (raw pointer events, no long-press delay); the
/// release decides: a quick touch that barely moved keeps recording.
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
  static const _tapTimeout = Duration(milliseconds: 300);

  double? _startY;

  /// The press is a hold (stop on release), not a tap.
  bool _held = false;
  Timer? _holdTimer;

  /// Recording started by a tap: the next touch stops it.
  bool _latched = false;

  /// The touch that stopped a tap recording; its release does nothing.
  bool _stopping = false;

  @override
  void didUpdateWidget(RecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Stopped from outside (time limit, error).
    if (oldWidget.recording && !widget.recording) _latched = false;
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  void _down(PointerDownEvent event) {
    if (_latched) {
      _latched = false;
      _stopping = true;
      widget.onStop();
      return;
    }
    if (!widget.enabled) return;
    _startY = event.position.dy;
    _held = false;
    _holdTimer = Timer(_tapTimeout, () => _held = true);
    widget.onStart();
  }

  void _move(PointerMoveEvent event) {
    final startY = _startY;
    if (startY == null) return;
    if ((startY - event.position.dy).abs() > kTouchSlop) _held = true;
    final travel = MediaQuery.sizeOf(context).height * 0.5;
    widget.onZoom(((startY - event.position.dy) / travel).clamp(0.0, 1.0));
  }

  void _end() {
    _holdTimer?.cancel();
    if (_stopping) {
      _stopping = false;
      return;
    }
    if (_startY == null) return;
    _startY = null;
    if (!_held) {
      _latched = true;
      return;
    }
    widget.onZoom(0);
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
          'Toca para grabar o mantén presionado; '
          'desliza hacia arriba para hacer zoom',
      child: Listener(
        onPointerDown: _down,
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

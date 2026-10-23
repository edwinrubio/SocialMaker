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

class _RecordButtonState extends State<RecordButton>
    with SingleTickerProviderStateMixin {
  static const _tapTimeout = Duration(milliseconds: 300);

  double? _startY;

  /// The press is a hold (stop on release), not a tap.
  bool _held = false;
  Timer? _holdTimer;

  /// Recording started by a tap: the next touch stops it.
  bool _latched = false;

  /// The touch that stopped a tap recording; its release does nothing.
  bool _stopping = false;

  /// Breathing ring while recording.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.recording) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(RecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.recording && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.recording && _pulse.isAnimating) {
      _pulse
        ..stop()
        ..value = 0;
    }
    // Stopped from outside (time limit, error).
    if (oldWidget.recording && !widget.recording) _latched = false;
  }

  @override
  void dispose() {
    _pulse.dispose();
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
      value: recording ? 'Grabando' : null,
      label:
          'Toca para grabar o mantén presionado; '
          'desliza hacia arriba para hacer zoom',
      child: Listener(
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: (_) => _end(),
        onPointerCancel: (_) => _end(),
        // Idle: red disc in a thin ring. Recording: the disc shrinks into a
        // rounded square (the stop sign) inside a larger, breathing ring.
        child: SizedBox.square(
          dimension: 112,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: _pulse,
                builder: (context, _) {
                  final t = Curves.easeInOut.transform(_pulse.value);
                  // Rebuilt every tick: a plain Container, not an animated one.
                  return Container(
                    width: recording ? 100 + 8 * t : 84,
                    height: recording ? 100 + 8 * t : 84,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: recording
                          ? red.withValues(alpha: 0.18 - 0.1 * t)
                          : Colors.transparent,
                      border: Border.all(
                        color: red.withValues(
                          alpha: !(enabled || recording)
                              ? 0.25
                              : recording
                              ? 0.9 - 0.4 * t
                              : 0.6,
                        ),
                        width: 6,
                      ),
                    ),
                  );
                },
              ),
              AnimatedContainer(
                key: const Key('record-button-core'),
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutBack,
                width: recording ? 36 : 70,
                height: recording ? 36 : 70,
                decoration: BoxDecoration(
                  color: enabled || recording
                      ? red
                      : red.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(recording ? 9 : 35),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

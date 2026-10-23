import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/material.dart';

import '../background/background_picker.dart';
import '../segments/segments_review_screen.dart';
import 'record_button.dart';
import 'recorder_controller.dart';
import 'segment_bar.dart';

class RecorderScreen extends StatefulWidget {
  const RecorderScreen({super.key});

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends State<RecorderScreen>
    with WidgetsBindingObserver {
  final _controller = RecorderController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _controller.stopSegment();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _chooseBackground() async {
    final choice = await showBackgroundPicker(
      context,
      current: _controller.backgroundType,
    );
    if (choice != null) {
      await _controller.setBackground(choice.type, path: choice.path);
    }
  }

  void _openReview() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SegmentsReviewScreen(controller: _controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final preview = _controller.preview;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (preview != null)
                _CameraPreview(preview: preview)
              else
                _Placeholder(
                  error: _controller.error,
                  onRetry: _controller.initialize,
                ),
              SafeArea(child: _buildOverlay()),
            ],
          );
        },
      ),
    );
  }

  Widget _buildOverlay() {
    final c = _controller;
    final hasSegments = c.segments.isNotEmpty;
    final seconds = c.liveDuration.inMilliseconds / 1000;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        children: [
          SegmentBar(
            segments: [for (final s in c.segments) s.duration],
            current: c.currentSegmentDuration,
            max: c.maxDuration,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '${seconds.toStringAsFixed(1)} s / ${c.maxDuration.inSeconds} s',
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                  shadows: [Shadow(blurRadius: 4)],
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Cambiar cámara',
                onPressed: c.isRecording ? null : c.switchCamera,
                icon: const Icon(Icons.cameraswitch_outlined),
              ),
            ],
          ),
          if (c.error != null && c.preview != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                c.error!,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _SideAction(
                icon: c.backgroundType == BackgroundType.none
                    ? Icons.wallpaper_outlined
                    : Icons.wallpaper,
                label: 'Fondo',
                onPressed: c.isRecording || c.preview == null
                    ? null
                    : _chooseBackground,
              ),
              RecordButton(
                recording: c.isRecording,
                enabled: c.canRecord,
                onStart: c.startSegment,
                onStop: c.stopSegment,
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SideAction(
                    icon: Icons.backspace_outlined,
                    label: 'Borrar',
                    onPressed: hasSegments && !c.isRecording
                        ? c.removeLastSegment
                        : null,
                  ),
                  const SizedBox(height: 12),
                  _SideAction(
                    icon: Icons.check_circle,
                    label: 'Listo',
                    onPressed: hasSegments && !c.isRecording
                        ? _openReview
                        : null,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            c.isRecording ? 'Grabando…' : 'Mantén presionado para grabar',
            style: const TextStyle(
              color: Colors.white70,
              shadows: [Shadow(blurRadius: 4)],
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraPreview extends StatelessWidget {
  const _CameraPreview({required this.preview});

  final CameraPreviewInfo preview;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: preview.width.toDouble(),
        height: preview.height.toDouble(),
        child: Texture(textureId: preview.textureId),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.error, required this.onRetry});

  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final error = this.error;
    if (error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }
}

class _SideAction extends StatelessWidget {
  const _SideAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final color = onPressed == null ? Colors.white30 : Colors.white;
    return InkResponse(
      onTap: onPressed,
      radius: 32,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            color: color,
            size: 30,
            shadows: const [Shadow(blurRadius: 6)],
          ),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }
}

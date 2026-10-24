import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/material.dart';

import '../export/export_screen.dart';
import '../filters/filters_sheet.dart';
import '../settings/settings_sheet.dart';
import '../segments/segment_strip.dart';
import '../segments/segment_viewer.dart';
import 'pip_overlay.dart';
import 'record_button.dart';
import 'recorder_controller.dart';
import 'segment_bar.dart';
import '../../brand.dart';

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

  Future<void> _openFilters() => showFiltersSheet(
    context,
    current: _controller.backgroundType,
    onBackground: (choice) =>
        _controller.setBackground(choice.type, path: choice.path),
    blurStrength: _controller.blurStrength,
    onBlurStrength: _controller.setBlurStrength,
  );

  /// Shows the fragment full screen (highlighted in the strip meanwhile);
  /// the user keeps, trims or deletes it there.
  Future<void> _openSegment(int index) async {
    final c = _controller;
    if (c.selectedIndex != index) c.toggleSelection(index);
    final decision = await showSegmentViewer(context, c.segments[index], index);
    if (decision is DeleteSegment) {
      c.removeSegmentAt(index);
      return;
    }
    if (decision case TrimSegment(:final start, :final end)) {
      c.trimSegmentAt(index, start, end);
    }
    if (c.selectedIndex == index) c.toggleSelection(index);
  }

  Future<void> _deleteAllSegments() async {
    final count = _controller.segments.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Borrar todos los fragmentos?'),
        content: Text(
          count == 1
              ? 'Se borrará el fragmento grabado. No se puede deshacer.'
              : 'Se borrarán los $count fragmentos grabados. '
                    'No se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Brand.pink),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Borrar todo'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) _controller.clearSegments();
  }

  Future<void> _openSettings() async {
    final c = _controller;
    final choice = await showSettingsSheet(
      context,
      current: (resolution: c.resolution, frameRate: c.frameRate),
      supportedResolutions: c.supportedResolutions,
      frameRatesFor: c.frameRatesFor,
      fragmentCount: c.segments.length,
    );
    if (choice == null) return;
    if (choice.resolution != c.resolution) {
      await c.changeResolution(choice.resolution);
    } else {
      await c.changeFrameRate(choice.frameRate);
    }
  }

  void _finish() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExportScreen(controller: _controller),
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
              if (preview != null && _controller.dualEnabled)
                PipOverlay(
                  frameSize: Size(
                    preview.width.toDouble(),
                    preview.height.toDouble(),
                  ),
                  origin: _controller.pipOrigin,
                  onMove: _controller.setPipOrigin,
                  onSwap: _controller.switchCamera,
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
    final idle = !c.isRecording;
    final hasSegments = c.segments.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        children: [
          SegmentBar(
            segments: [for (final s in c.segments) s.length],
            current: c.currentSegmentDuration,
            max: c.maxDuration,
          ),
          if (c.error != null && c.preview != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Text(c.error!, textAlign: TextAlign.center),
                ),
              ),
            ),
          const Spacer(),
          if (hasSegments) ...[
            Row(
              children: [
                Expanded(
                  child: SegmentStrip(
                    segments: c.segments,
                    selectedIndex: c.selectedIndex,
                    onTap: idle ? _openSegment : (_) {},
                  ),
                ),
                const SizedBox(width: 8),
                _ControlButton(
                  key: const Key('delete-all-segments'),
                  icon: Icons.delete_sweep_outlined,
                  tooltip: 'Borrar todos los fragmentos',
                  onPressed: idle ? _deleteAllSegments : null,
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _Timer(duration: c.liveDuration, recording: c.isRecording),
              _ControlButton(
                icon: Icons.backspace_outlined,
                tooltip: c.selectedIndex == null
                    ? 'Borrar último fragmento'
                    : 'Borrar fragmento ${c.selectedIndex! + 1}',
                onPressed: hasSegments && idle
                    ? c.removeSelectedOrLastSegment
                    : null,
              ),
              RecordButton(
                recording: c.isRecording,
                enabled: c.canRecord,
                onStart: c.startSegment,
                onStop: c.stopSegment,
                onZoom: c.setZoom,
              ),
              _ControlButton(
                icon: Icons.check_circle,
                tooltip: 'Listo: unir fragmentos',
                color: Brand.pink,
                onPressed: hasSegments && idle ? _finish : null,
              ),
              _ControlButton(
                icon: Icons.cameraswitch_outlined,
                tooltip: c.dualEnabled
                    ? 'Intercambiar cámaras'
                    : 'Cambiar cámara',
                onPressed: c.preview != null ? c.switchCamera : null,
              ),
            ],
          ),
          const SizedBox(height: 12),
          // One line; shrinks a little on narrow phones instead of overflowing.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PillButton(
                  icon: Icons.auto_awesome,
                  label: 'Filtros',
                  active: c.backgroundType != BackgroundType.none,
                  onPressed: idle && c.preview != null ? _openFilters : null,
                ),
                const SizedBox(width: 8),
                _PillButton(
                  icon: Icons.settings_outlined,
                  label: '${c.resolution.label} · ${c.frameRate.fps}',
                  tooltip: 'Configuración',
                  onPressed: idle && c.preview != null ? _openSettings : null,
                ),
                const SizedBox(width: 8),
                _PillButton(
                  icon: Icons.picture_in_picture_alt_outlined,
                  label: '2 cámaras',
                  tooltip: 'Grabar con las dos cámaras',
                  active: c.dualEnabled,
                  onPressed: idle && c.preview != null ? c.toggleDual : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Timer extends StatelessWidget {
  const _Timer({required this.duration, required this.recording});

  final Duration duration;
  final bool recording;

  @override
  Widget build(BuildContext context) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: recording ? Brand.pink : Colors.black45,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$minutes:$seconds',
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color = Colors.white,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 32,
      color: color,
      disabledColor: Colors.white30,
      icon: Icon(icon, shadows: const [Shadow(blurRadius: 6)]),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final bool active;
  final String? tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: Colors.black45,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: active ? Brand.pink : Colors.white),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: onPressed == null ? Colors.white38 : Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final tooltip = this.tooltip;
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
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

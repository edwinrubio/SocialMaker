import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/material.dart';

/// What the recording settings sheet changes.
typedef VideoSettings = ({
  VideoResolution resolution,
  VideoFrameRate frameRate,
});

/// Resolution and frame-rate picker. Resolves to the new settings, or null if
/// the sheet was dismissed or nothing changed.
Future<VideoSettings?> showSettingsSheet(
  BuildContext context, {
  required VideoSettings current,
  required List<VideoResolution> supportedResolutions,
  required List<VideoFrameRate> Function(VideoResolution) frameRatesFor,
  required int fragmentCount,
  bool dualEnabled = false,
  List<VideoResolution> dualResolutions = const [],
}) {
  return showModalBottomSheet<VideoSettings>(
    context: context,
    backgroundColor: const Color(0xEE161616),
    showDragHandle: true,
    builder: (_) => _SettingsSheet(
      current: current,
      supportedResolutions: supportedResolutions,
      frameRatesFor: frameRatesFor,
      fragmentCount: fragmentCount,
      dualEnabled: dualEnabled,
      dualResolutions: dualResolutions,
    ),
  );
}

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet({
    required this.current,
    required this.supportedResolutions,
    required this.frameRatesFor,
    required this.fragmentCount,
    required this.dualEnabled,
    required this.dualResolutions,
  });

  final VideoSettings current;
  final List<VideoResolution> supportedResolutions;
  final List<VideoFrameRate> Function(VideoResolution) frameRatesFor;
  final int fragmentCount;
  final bool dualEnabled;

  /// What the device records with both cameras; only these while
  /// [dualEnabled].
  final List<VideoResolution> dualResolutions;

  bool _available(VideoResolution value) =>
      supportedResolutions.contains(value) &&
      (!dualEnabled || dualResolutions.contains(value));

  Future<void> _choose(BuildContext context, VideoSettings value) async {
    if (value == current) {
      Navigator.pop(context);
      return;
    }
    if (fragmentCount > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('¿Cambiar la configuración?'),
          content: Text(
            'Todos los fragmentos de un video deben tener la misma resolución '
            'y los mismos fps. Se borrará${fragmentCount == 1 ? '' : 'n'} '
            '$fragmentCount fragmento${fragmentCount == 1 ? '' : 's'}.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Cambiar'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (context.mounted) Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: Colors.white60);
    final rates = frameRatesFor(current.resolution);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Configuración', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            Text('Resolución del video', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final resolution in VideoResolution.values)
                  ChoiceChip(
                    label: Text(resolution.label),
                    selected: resolution == current.resolution,
                    onSelected: _available(resolution)
                        ? (_) => _choose(context, (
                            resolution: resolution,
                            frameRate: current.frameRate,
                          ))
                        : null,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              !supportedResolutions.contains(VideoResolution.p2160)
                  ? 'Este teléfono no puede grabar en 4K con efectos.'
                  : !_available(VideoResolution.p2160)
                  ? 'Este teléfono no graba en 4K con las dos cámaras.'
                  : 'Más resolución = más calidad y archivos más grandes.',
              style: hint,
            ),
            const SizedBox(height: 20),
            Text('Fotogramas por segundo', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final rate in VideoFrameRate.values)
                  ChoiceChip(
                    label: Text(rate.label),
                    selected: rate == current.frameRate,
                    onSelected: rates.contains(rate)
                        ? (_) => _choose(context, (
                            resolution: current.resolution,
                            frameRate: rate,
                          ))
                        : null,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              rates.contains(VideoFrameRate.fps60)
                  ? '24 fps: aspecto de cine · 30 fps: estándar · '
                        '60 fps: movimiento más fluido.'
                  : 'Este teléfono no graba a 60 fps en '
                        '${current.resolution.label}.',
              style: hint,
            ),
          ],
        ),
      ),
    );
  }
}

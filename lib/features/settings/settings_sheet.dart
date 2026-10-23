import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/material.dart';

/// Output-resolution picker. Resolves to the chosen value, or null if the
/// sheet was dismissed or the user kept the current one.
Future<VideoResolution?> showSettingsSheet(
  BuildContext context, {
  required VideoResolution current,
  required List<VideoResolution> supported,
  required int fragmentCount,
}) {
  return showModalBottomSheet<VideoResolution>(
    context: context,
    backgroundColor: const Color(0xEE161616),
    showDragHandle: true,
    builder: (_) => _SettingsSheet(
      current: current,
      supported: supported,
      fragmentCount: fragmentCount,
    ),
  );
}

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet({
    required this.current,
    required this.supported,
    required this.fragmentCount,
  });

  final VideoResolution current;
  final List<VideoResolution> supported;
  final int fragmentCount;

  Future<void> _choose(BuildContext context, VideoResolution value) async {
    if (value == current) {
      Navigator.pop(context);
      return;
    }
    if (fragmentCount > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('¿Cambiar la resolución?'),
          content: Text(
            'Todos los fragmentos de un video deben tener la misma resolución. '
            'Se borrará${fragmentCount == 1 ? '' : 'n'} $fragmentCount '
            'fragmento${fragmentCount == 1 ? '' : 's'}.',
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
                    selected: resolution == current,
                    onSelected: supported.contains(resolution)
                        ? (_) => _choose(context, resolution)
                        : null,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              supported.contains(VideoResolution.p2160)
                  ? 'Más resolución = más calidad y archivos más grandes.'
                  : 'Este teléfono no puede grabar en 4K con efectos.',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }
}

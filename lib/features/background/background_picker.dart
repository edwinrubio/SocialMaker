import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Chosen background: a type plus the file for image/video backgrounds.
typedef BackgroundChoice = ({BackgroundType type, String? path});

/// Bottom sheet to remove the background or replace it with a photo or video.
Future<BackgroundChoice?> showBackgroundPicker(
  BuildContext context, {
  required BackgroundType current,
}) {
  return showModalBottomSheet<BackgroundChoice>(
    context: context,
    backgroundColor: const Color(0xFF161616),
    showDragHandle: true,
    builder: (context) => _BackgroundSheet(current: current),
  );
}

class _BackgroundSheet extends StatelessWidget {
  const _BackgroundSheet({required this.current});

  final BackgroundType current;

  Future<void> _pick(BuildContext context, BackgroundType type) async {
    if (type == BackgroundType.none) {
      Navigator.pop(context, (type: type, path: null));
      return;
    }
    final picker = ImagePicker();
    final file = type == BackgroundType.image
        ? await picker.pickImage(source: ImageSource.gallery)
        : await picker.pickVideo(source: ImageSource.gallery);
    if (file != null && context.mounted) {
      Navigator.pop(context, (type: type, path: file.path));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Fondo', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Quita el fondo detrás de ti y cámbialo por una foto o un video.',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: Colors.white60),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                for (final (type, icon, label) in const [
                  (BackgroundType.none, Icons.block, 'Ninguno'),
                  (BackgroundType.image, Icons.image_outlined, 'Foto'),
                  (BackgroundType.video, Icons.movie_outlined, 'Video'),
                ])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: _Option(
                        icon: icon,
                        label: label,
                        selected: current == type,
                        onTap: () => _pick(context, type),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0x33FE2C55) : Colors.white10,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? const Color(0xFFFE2C55) : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Column(
            children: [
              Icon(icon, size: 28),
              const SizedBox(height: 8),
              Text(label),
            ],
          ),
        ),
      ),
    );
  }
}

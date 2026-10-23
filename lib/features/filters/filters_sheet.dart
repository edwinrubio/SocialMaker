import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Chosen background: a type plus the file for image/video backgrounds.
typedef BackgroundChoice = ({BackgroundType type, String? path});

/// TikTok-style filter panel. Choices apply immediately while the panel stays
/// open over the live preview.
Future<void> showFiltersSheet(
  BuildContext context, {
  required BackgroundType current,
  required Future<void> Function(BackgroundChoice choice) onBackground,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xEE161616),
    barrierColor: Colors.transparent,
    showDragHandle: true,
    builder: (_) => _FiltersSheet(current: current, onBackground: onBackground),
  );
}

enum _Category { backgrounds }

class _FiltersSheet extends StatefulWidget {
  const _FiltersSheet({required this.current, required this.onBackground});

  final BackgroundType current;
  final Future<void> Function(BackgroundChoice choice) onBackground;

  @override
  State<_FiltersSheet> createState() => _FiltersSheetState();
}

class _FiltersSheetState extends State<_FiltersSheet> {
  late BackgroundType _selected = widget.current;
  final _category = _Category.backgrounds;
  bool _applying = false;

  Future<void> _choose(BackgroundType type) async {
    String? path;
    if (type == BackgroundType.image || type == BackgroundType.video) {
      final picker = ImagePicker();
      final file = type == BackgroundType.image
          ? await picker.pickImage(source: ImageSource.gallery)
          : await picker.pickVideo(source: ImageSource.gallery);
      if (file == null) return;
      path = file.path;
    }
    setState(() => _applying = true);
    try {
      await widget.onBackground((type: type, path: path));
      if (mounted) setState(() => _selected = type);
    } finally {
      if (mounted) setState(() => _applying = false);
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
            Row(
              children: [
                Text('Filtros', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                if (_applying)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('Fondos'),
                    selected: _category == _Category.backgrounds,
                    onSelected: (_) {},
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Quita o desenfoca el fondo detrás de ti, o cámbialo por una foto o un video.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Colors.white60),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (final (type, icon, label) in const [
                  (BackgroundType.none, Icons.block, 'Ninguno'),
                  (BackgroundType.image, Icons.image_outlined, 'Foto'),
                  (BackgroundType.video, Icons.movie_outlined, 'Video'),
                  (BackgroundType.blur, Icons.blur_on, 'Desenfocar'),
                ])
                  _FilterOption(
                    icon: icon,
                    label: label,
                    selected: _selected == type,
                    onTap: _applying ? null : () => _choose(type),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterOption extends StatelessWidget {
  const _FilterOption({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFFE2C55);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: 40,
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white10,
                border: Border.all(
                  color: selected ? accent : Colors.transparent,
                  width: 2.5,
                ),
              ),
              child: Icon(icon, size: 28),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: selected ? accent : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

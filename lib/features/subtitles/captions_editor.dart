import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/material.dart';

/// Lets the user fix each phrase's text (or delete it) before it is burned in.
/// Resolves to the edited list, or null if dismissed.
Future<List<Caption>?> showCaptionsEditor(
  BuildContext context,
  List<Caption> captions,
) {
  return showModalBottomSheet<List<Caption>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF161616),
    showDragHandle: true,
    builder: (_) => _CaptionsEditor(captions: captions),
  );
}

class _CaptionsEditor extends StatefulWidget {
  const _CaptionsEditor({required this.captions});

  final List<Caption> captions;

  @override
  State<_CaptionsEditor> createState() => _CaptionsEditorState();
}

class _CaptionsEditorState extends State<_CaptionsEditor> {
  late final List<Caption> _captions = [...widget.captions];
  late final List<TextEditingController> _texts = [
    for (final caption in widget.captions)
      TextEditingController(text: caption.text),
  ];

  @override
  void dispose() {
    for (final controller in _texts) {
      controller.dispose();
    }
    super.dispose();
  }

  void _remove(int index) => setState(() {
    _captions.removeAt(index);
    _texts.removeAt(index).dispose();
  });

  void _save() {
    Navigator.pop(context, [
      for (var i = 0; i < _captions.length; i++)
        if (_texts[i].text.trim().isNotEmpty)
          _captions[i].copyWith(text: _texts[i].text.trim()),
    ]);
  }

  static String _time(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inMilliseconds % 60000 / 1000).toStringAsFixed(1);
    return '$minutes:${seconds.padLeft(4, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                child: Row(
                  children: [
                    Text(
                      'Editar subtítulos',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    FilledButton(onPressed: _save, child: const Text('Listo')),
                  ],
                ),
              ),
              Flexible(
                child: _captions.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(32),
                        child: Text('No quedan subtítulos.'),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(16, 0, 8, 16),
                        itemCount: _captions.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final caption = _captions[index];
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 64,
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 14),
                                  child: Text(
                                    '${_time(caption.start)}\n${_time(caption.end)}',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 12,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: TextField(
                                  controller: _texts[index],
                                  minLines: 1,
                                  maxLines: 3,
                                  decoration: const InputDecoration(
                                    filled: true,
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Quitar esta frase',
                                onPressed: () => _remove(index),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

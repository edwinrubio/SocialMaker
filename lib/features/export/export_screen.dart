import 'dart:io';
import 'dart:ui';

import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart' hide Caption;

import '../recorder/recorder_controller.dart';
import '../subtitles/caption_grouper.dart';
import '../subtitles/captions_editor.dart';
import '../../brand.dart';

/// Merges the fragments, previews the result, optionally adds subtitles, and
/// saves or shares it.
class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key, required this.controller});

  final RecorderController controller;

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  String? _path;
  String? _error;
  VideoPlayerController? _player;

  bool _subtitlesSupported = false;
  late String _language = _defaultLanguage();
  List<Caption>? _captions;
  bool _includeCaptions = true;
  bool _transcribing = false;

  /// Last video rendered with subtitles, reused while the captions are unchanged.
  ({List<Caption> captions, String path})? _burned;

  bool _busy = false;
  bool _saved = false;

  BgCamera get _camera => widget.controller.camera;

  @override
  void initState() {
    super.initState();
    _export();
    _camera.subtitlesSupported().then((supported) {
      if (mounted) setState(() => _subtitlesSupported = supported);
    });
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    try {
      final path = await widget.controller.export();
      final player = VideoPlayerController.file(File(path));
      await player.initialize();
      await player.setLooping(true);
      await player.play();
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _path = path;
        _player = player;
      });
    } on PlatformException catch (e) {
      setState(() => _error = e.message ?? 'No se pudo exportar el video.');
    }
  }

  Future<void> _generateCaptions() async {
    setState(() => _transcribing = true);
    try {
      final words = await _camera.transcribe(
        _path!,
        localeId: _languages[_language]!,
      );
      final captions = groupWords(words);
      setState(() {
        _captions = captions;
        _includeCaptions = true;
      });
      if (captions.isEmpty) _snack('No se detectó voz en el video.');
    } on PlatformException catch (e) {
      _snack('No se pudieron generar los subtítulos: ${e.message}');
    } finally {
      if (mounted) setState(() => _transcribing = false);
    }
  }

  Future<void> _editCaptions() async {
    final edited = await showCaptionsEditor(context, _captions ?? const []);
    if (edited != null) setState(() => _captions = edited);
  }

  /// The video to save or share: with subtitles burned in when enabled.
  Future<String> _finalPath() async {
    final captions = _captions;
    if (!_includeCaptions || captions == null || captions.isEmpty) {
      return _path!;
    }
    final burned = _burned;
    if (burned != null && listEquals(burned.captions, captions)) {
      return burned.path;
    }
    final path = await _camera.burnSubtitles(_path!, captions);
    _burned = (captions: captions, path: path);
    return path;
  }

  Future<void> _run(Future<void> Function(String path) action) async {
    setState(() => _busy = true);
    try {
      await action(await _finalPath());
    } on PlatformException catch (e) {
      _snack('Algo falló: ${e.message}');
    } on GalException catch (e) {
      _snack('No se pudo guardar: ${e.type.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _run((path) async {
    await Gal.putVideo(path);
    if (mounted) setState(() => _saved = true);
  });

  /// [app] is `tiktok`, `instagram`, `youtube`, or null for the share sheet.
  Future<void> _share(String? app, String label) => _run((path) async {
    if (app != null) {
      switch (await _camera.shareToApp(path, app: app)) {
        case ShareOutcome.opened:
          return;
        case ShareOutcome.openedSaved:
          if (mounted) setState(() => _saved = true);
          _snack(
            'Video guardado en Fotos: en $label elige el más reciente de tu galería.',
          );
          return;
        case ShareOutcome.notInstalled:
          _snack('$label no está instalada; elige dónde compartir.');
      }
    }
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: 'video/mp4')],
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  });

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _startOver() {
    widget.controller.clearSegments();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final ready = _path != null && !_busy;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Tu video'),
      ),
      body: Column(
        children: [
          Expanded(child: Center(child: _buildPreview())),
          if (_subtitlesSupported && _path != null) _buildSubtitlesRow(),
          if (_path != null) _buildShareRow(ready),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: ready ? _startOver : null,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: const Text('Nuevo video'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: ready && !_saved ? _save : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: Brand.pink,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      icon: _busy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(_saved ? Icons.check : Icons.download),
                      label: Text(_saved ? 'Guardado' : 'Guardar'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Text(error, textAlign: TextAlign.center),
      );
    }
    final player = _player;
    if (player == null) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Uniendo fragmentos…'),
        ],
      );
    }
    final captions = _includeCaptions ? _captions : null;
    return AspectRatio(
      aspectRatio: player.value.aspectRatio,
      child: Stack(
        fit: StackFit.expand,
        children: [
          VideoPlayer(player),
          if (captions != null && captions.isNotEmpty)
            _CaptionOverlay(player: player, captions: captions),
        ],
      ),
    );
  }

  Widget _buildSubtitlesRow() {
    final captions = _captions;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: captions == null
          ? Row(
              children: [
                DropdownButton<String>(
                  key: const Key('subtitles-language'),
                  value: _language,
                  underline: const SizedBox.shrink(),
                  onChanged: _transcribing
                      ? null
                      : (value) => setState(() => _language = value!),
                  items: [
                    for (final name in _languages.keys)
                      DropdownMenuItem(value: name, child: Text(name)),
                  ],
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _transcribing || _busy
                        ? null
                        : _generateCaptions,
                    icon: _transcribing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.closed_caption_outlined),
                    label: Text(
                      _transcribing
                          ? 'Generando subtítulos…'
                          : 'Generar subtítulos con IA',
                    ),
                  ),
                ),
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.closed_caption_outlined),
                    title: const Text('Subtítulos en el video'),
                    subtitle: Text(
                      _includeCaptions
                          ? 'Se verán en el video que guardes o compartas.'
                          : 'El video se guardará sin subtítulos.',
                      style: const TextStyle(color: Colors.white60),
                    ),
                    value: _includeCaptions,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _includeCaptions = value),
                  ),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _editCaptions,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Editar texto'),
                ),
              ],
            ),
    );
  }

  Widget _buildShareRow(bool ready) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Compartir en', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (final (app, label, icon, color) in const [
                ('tiktok', 'TikTok', Icons.music_note, Color(0xFF25F4EE)),
                ('instagram', 'Instagram', Icons.camera_alt, Color(0xFFE1306C)),
                ('youtube', 'Shorts', Icons.play_arrow, Color(0xFFFF0000)),
                (null, 'Más', Icons.ios_share, Colors.white70),
              ])
                _ShareButton(
                  label: label,
                  icon: icon,
                  color: color,
                  onPressed: ready ? () => _share(app, label) : null,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shows the caption for the player's current position, styled like the
/// burned-in subtitles.
/// Languages offered for subtitles (shown name → BCP-47 tag).
const _languages = {
  'Español': 'es-MX',
  'English': 'en-US',
  'Português': 'pt-BR',
};

/// Spanish unless the phone is set to one of the other offered languages.
String _defaultLanguage() {
  final code = PlatformDispatcher.instance.locale.languageCode;
  return switch (code) {
    'en' => 'English',
    'pt' => 'Português',
    _ => 'Español',
  };
}

class _CaptionOverlay extends StatelessWidget {
  const _CaptionOverlay({required this.player, required this.captions});

  final VideoPlayerController player;
  final List<Caption> captions;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final fontSize = constraints.maxHeight * 0.045;
        final style = TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          height: 1.15,
        );
        return ValueListenableBuilder(
          valueListenable: player,
          builder: (context, value, _) {
            final caption = captionAt(captions, value.position);
            if (caption == null) return const SizedBox.shrink();
            return Align(
              alignment: const Alignment(0, 0.62),
              child: FractionallySizedBox(
                widthFactor: 0.85,
                child: Stack(
                  children: [
                    Text(
                      caption.text,
                      textAlign: TextAlign.center,
                      style: style.copyWith(
                        foreground: Paint()
                          ..style = PaintingStyle.stroke
                          ..strokeWidth = fontSize * 0.12
                          ..color = Colors.black,
                      ),
                    ),
                    Text(
                      caption.text,
                      textAlign: TextAlign.center,
                      style: style.copyWith(color: Colors.white),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ShareButton extends StatelessWidget {
  const _ShareButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onPressed,
      radius: 36,
      child: Opacity(
        opacity: onPressed == null ? 0.4 : 1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: Colors.white10,
              child: Icon(icon, color: color),
            ),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

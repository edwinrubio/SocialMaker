import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:video_player/video_player.dart';

import '../recorder/recorder_controller.dart';

/// Merges the fragments, previews the result and saves it to the gallery.
class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key, required this.controller});

  final RecorderController controller;

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  String? _path;
  String? _error;
  bool _saving = false;
  bool _saved = false;
  VideoPlayerController? _player;

  @override
  void initState() {
    super.initState();
    _export();
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

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await Gal.putVideo(_path!);
      setState(() => _saved = true);
    } on GalException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo guardar: ${e.type.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _startOver() {
    widget.controller.clearSegments();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final error = _error;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Tu video'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: error != null
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(error, textAlign: TextAlign.center),
                    )
                  : player == null
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Uniendo fragmentos…'),
                      ],
                    )
                  : AspectRatio(
                      aspectRatio: player.value.aspectRatio,
                      child: VideoPlayer(player),
                    ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _path == null ? null : _startOver,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: const Text('Nuevo video'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _path == null || _saving || _saved
                          ? null
                          : _save,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFE2C55),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      icon: Icon(_saved ? Icons.check : Icons.download),
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
}

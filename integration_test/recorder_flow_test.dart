// Drives the real app on a simulator/device: records fragments by holding the
// button, selects and deletes one, applies a photo background and merges.
//
// On the iOS Simulator the camera is fed from ~/Library/Caches/SocialMaker/
// fake_camera.mp4 on the Mac; the background photo is bg_test.jpg in the same
// folder (or in the app's Documents on a device).
//
//   flutter test integration_test/recorder_flow_test.dart -d <device>
//
// Each step prints "STEP <name>" and pauses so screenshots can be taken.
import 'dart:io';

import 'package:bg_camera/bg_camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:social_maker/features/recorder/record_button.dart';
import 'package:social_maker/features/subtitles/caption_grouper.dart';
import 'package:social_maker/main.dart';
import 'package:video_player/video_player.dart' hide Caption;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> wait(WidgetTester tester, Duration duration) async {
    final end = DateTime.now().add(duration);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> step(WidgetTester tester, String name) async {
    // ignore: avoid_print
    print('STEP $name');
    await wait(tester, const Duration(seconds: 4));
  }

  /// Holds the record button; with [slideUp], drags the finger up halfway
  /// through (zoom).
  Future<void> hold(
    WidgetTester tester,
    Duration duration, {
    double slideUp = 0,
  }) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(RecordButton)),
    );
    await wait(tester, duration ~/ 2);
    if (slideUp > 0) await gesture.moveBy(Offset(0, -slideUp));
    await wait(tester, duration ~/ 2);
    await gesture.up();
    await wait(tester, const Duration(seconds: 2));
  }

  /// Taps to start recording and taps again after [duration] to stop.
  Future<void> tapRecord(WidgetTester tester, Duration duration) async {
    await tester.tap(find.byType(RecordButton));
    await wait(tester, duration);
    await tester.tap(find.byType(RecordButton));
    await wait(tester, const Duration(seconds: 2));
  }

  testWidgets('record, select and delete, background, merge', (tester) async {
    await tester.pumpWidget(const SocialMakerApp());
    await wait(tester, const Duration(seconds: 5));
    await step(tester, 'preview');

    // On the simulator the app container lives under the Mac's home folder.
    final documents = (await getApplicationDocumentsDirectory()).path;
    final simulatorAt = documents.indexOf('/Library/Developer/CoreSimulator/');
    final folder = simulatorAt >= 0
        ? '${documents.substring(0, simulatorAt)}/Library/Caches/SocialMaker'
        : documents;
    final background = File('$folder/bg_test.jpg');
    if (background.existsSync()) {
      await BgCamera().setBackground(
        BackgroundType.image,
        path: background.path,
      );
      await step(tester, 'background');
    } else {
      // ignore: avoid_print
      print('SKIP background: no ${background.path}');
    }

    await hold(tester, const Duration(milliseconds: 2500));
    await tapRecord(tester, const Duration(milliseconds: 1500));
    await hold(tester, const Duration(seconds: 3), slideUp: 250);
    expect(find.bySemanticsLabel(RegExp('^Fragmento 3')), findsOneWidget);
    await step(tester, 'three-fragments');

    await tester.tap(find.bySemanticsLabel(RegExp('^Fragmento 2')));
    await wait(tester, const Duration(seconds: 1));
    expect(find.text('Borrar fragmento'), findsOneWidget);
    await step(tester, 'viewer-2');

    await tester.tap(find.text('Borrar fragmento'));
    await wait(tester, const Duration(seconds: 1));
    expect(find.bySemanticsLabel(RegExp('^Fragmento 3')), findsNothing);
    await step(tester, 'deleted-2');

    await tester.tap(find.byIcon(Icons.check_circle));
    await wait(tester, const Duration(seconds: 8));
    expect(find.text('Tu video'), findsOneWidget);
    expect(find.byType(VideoPlayer), findsOneWidget, reason: 'export failed');
    await step(tester, 'exported');

    final camera = BgCamera();
    if (!await camera.subtitlesSupported()) return;

    final merged =
        Directory.systemTemp
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('socialmaker_'))
            .toList()
          ..sort(
            (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
          );

    List<Caption> captions;
    if (simulatorAt >= 0) {
      // The Simulator has no SpeechTranscriber model and the fallback asks
      // for a permission no tool can grant there; burn known captions.
      captions = const [
        Caption(
          start: Duration.zero,
          end: Duration(milliseconds: 1800),
          text: 'Hola a todos',
        ),
        Caption(
          start: Duration(milliseconds: 1800),
          end: Duration(milliseconds: 4000),
          text: 'bienvenidos a mi canal',
        ),
      ];
    } else {
      await tester.tap(find.byKey(const Key('subtitles-language')));
      await wait(tester, const Duration(seconds: 1));
      await tester.tap(find.text('Español').last);
      await wait(tester, const Duration(seconds: 1));
      await tester.tap(find.text('Generar subtítulos con IA'));
      for (
        var i = 0;
        i < 120 && find.text('Subtítulos en el video').evaluate().isEmpty;
        i++
      ) {
        await wait(tester, const Duration(seconds: 1));
      }
      expect(
        find.text('Subtítulos en el video'),
        findsOneWidget,
        reason: 'no captions',
      );
      await step(tester, 'captions');
      captions = groupWords(
        await camera.transcribe(merged.first.path, localeId: 'es-MX'),
      );
    }
    // ignore: avoid_print
    print(
      'CAPTIONS ${[for (final c in captions) '${c.start.inMilliseconds}-${c.end.inMilliseconds} ${c.text}']}',
    );
    final burned = await camera.burnSubtitles(merged.first.path, captions);
    // ignore: avoid_print
    print('BURNED $burned');
    expect(File(burned).existsSync(), isTrue);
    // The app (and its tmp) is removed after the run; keep a copy to inspect.
    if (simulatorAt >= 0) {
      File(burned).copySync('$folder/burned_test.mp4');
      merged.first.copySync('$folder/merged_test.mp4');
    }
  });
}

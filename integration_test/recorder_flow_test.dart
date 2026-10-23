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
import 'package:social_maker/main.dart';
import 'package:video_player/video_player.dart';

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

  Future<void> hold(WidgetTester tester, Duration duration) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(RecordButton)),
    );
    await wait(tester, duration);
    await gesture.up();
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
    expect(background.existsSync(), isTrue, reason: 'copy bg_test.jpg first');
    await BgCamera().setBackground(BackgroundType.image, path: background.path);
    await step(tester, 'background');

    await hold(tester, const Duration(seconds: 2));
    await hold(tester, const Duration(milliseconds: 1500));
    await hold(tester, const Duration(milliseconds: 2500));
    expect(find.bySemanticsLabel(RegExp('^Fragmento 3')), findsOneWidget);
    await step(tester, 'three-fragments');

    await tester.tap(find.bySemanticsLabel(RegExp('^Fragmento 2')));
    await step(tester, 'selected-2');

    await tester.tap(find.byIcon(Icons.backspace_outlined));
    await wait(tester, const Duration(seconds: 1));
    expect(find.bySemanticsLabel(RegExp('^Fragmento 3')), findsNothing);
    await step(tester, 'deleted-2');

    await tester.tap(find.byIcon(Icons.check_circle));
    await wait(tester, const Duration(seconds: 8));
    expect(find.text('Tu video'), findsOneWidget);
    expect(find.byType(VideoPlayer), findsOneWidget, reason: 'export failed');
    await step(tester, 'exported');
  });
}

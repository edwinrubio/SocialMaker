import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_maker/features/recorder/record_button.dart';

void main() {
  late int starts;
  late int stops;
  late List<double> zooms;
  late bool recording;

  setUp(() {
    starts = 0;
    stops = 0;
    zooms = [];
    recording = false;
  });

  Widget button() => MaterialApp(
    home: Scaffold(
      body: Center(
        child: RecordButton(
          recording: recording,
          enabled: true,
          onStart: () {
            starts++;
            recording = true;
          },
          onStop: () {
            stops++;
            recording = false;
          },
          onZoom: zooms.add,
        ),
      ),
    ),
  );

  Future<void> press(WidgetTester tester, Duration duration) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(RecordButton)),
    );
    await tester.pump(duration);
    await gesture.up();
    await tester.pumpWidget(button());
  }

  testWidgets('a tap starts recording and the next tap stops it', (
    tester,
  ) async {
    await tester.pumpWidget(button());
    await press(tester, const Duration(milliseconds: 100));
    expect((starts, stops), (1, 0));

    await press(tester, const Duration(milliseconds: 100));
    expect((starts, stops), (1, 1));
    expect(zooms, isEmpty);
  });

  testWidgets('holding records until release', (tester) async {
    await tester.pumpWidget(button());
    await press(tester, const Duration(milliseconds: 500));
    expect((starts, stops), (1, 1));
    expect(zooms, [0]);
  });

  testWidgets('sliding up while holding zooms, release resets', (tester) async {
    await tester.pumpWidget(button());
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(RecordButton)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, -150));
    await gesture.up();
    expect(zooms.first, greaterThan(0));
    expect(zooms.last, 0);
    expect((starts, stops), (1, 1));
  });

  testWidgets('after a stop from outside, a tap records again', (tester) async {
    await tester.pumpWidget(button());
    await press(tester, const Duration(milliseconds: 100));
    recording = false; // e.g. the 10-minute limit
    await tester.pumpWidget(button());

    await press(tester, const Duration(milliseconds: 100));
    expect((starts, stops), (2, 0));
  });

  testWidgets('the core turns into a small square while recording', (
    tester,
  ) async {
    await tester.pumpWidget(button());
    final idle = tester.getSize(find.byKey(const Key('record-button-core')));

    await press(tester, const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    final recordingSize = tester.getSize(
      find.byKey(const Key('record-button-core')),
    );
    expect(recordingSize.width, lessThan(idle.width / 1.5));
  });
}

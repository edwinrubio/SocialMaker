import 'package:bg_camera/bg_camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_maker/features/subtitles/caption_grouper.dart';

Caption word(int startMs, int endMs, String text) => Caption(
  start: Duration(milliseconds: startMs),
  end: Duration(milliseconds: endMs),
  text: text,
);

void main() {
  test('splits on pauses and sentence ends, attaches punctuation', () {
    final phrases = groupWords([
      word(0, 300, 'Hola'),
      word(300, 600, 'a'),
      word(600, 900, 'todos'),
      word(900, 950, '.'),
      word(1000, 1300, 'Hoy'),
      word(1300, 1600, 'les'),
      word(1600, 1900, 'cuento'),
      word(3000, 3300, 'algo'),
    ]);

    expect(
      [for (final p in phrases) p.text],
      ['Hola a todos.', 'Hoy les cuento', 'algo'],
    );
    expect(phrases.first.start, Duration.zero);
    expect(phrases.first.end, const Duration(milliseconds: 950));
    expect(phrases[2].start, const Duration(milliseconds: 3000));
  });

  test('caps phrases by word count and duration', () {
    final words = [
      for (var i = 0; i < 9; i++) word(i * 200, i * 200 + 180, 'w$i'),
    ];
    final byCount = groupWords(words, maxWords: 4);
    expect(
      [for (final p in byCount) p.text],
      ['w0 w1 w2 w3', 'w4 w5 w6 w7', 'w8'],
    );

    final byLength = groupWords(
      words,
      maxLength: const Duration(milliseconds: 700),
    );
    expect(byLength.first.text, 'w0 w1 w2');
  });

  test('captionAt finds the caption on screen', () {
    final captions = [word(0, 1000, 'uno'), word(1500, 2500, 'dos')];
    expect(captionAt(captions, const Duration(milliseconds: 500))?.text, 'uno');
    expect(captionAt(captions, const Duration(milliseconds: 1200)), isNull);
    expect(
      captionAt(captions, const Duration(milliseconds: 1500))?.text,
      'dos',
    );
  });
}

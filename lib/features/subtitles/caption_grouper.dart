import 'package:bg_camera/bg_camera.dart';

final _sentenceEnd = RegExp(r'[.!?…]$');
final _leadingPunctuation = RegExp(r'^[.,!?;:…)\]]');

/// Joins timed words into short on-screen phrases: a new phrase starts after
/// [maxWords] words, when it would last longer than [maxLength], after a
/// pause of [pause] or after the end of a sentence.
List<Caption> groupWords(
  List<Caption> words, {
  int maxWords = 6,
  Duration maxLength = const Duration(milliseconds: 2500),
  Duration pause = const Duration(milliseconds: 600),
}) {
  final phrases = <Caption>[];
  final current = <Caption>[];

  void flush() {
    if (current.isEmpty) return;
    final text = StringBuffer();
    for (final word in current) {
      final token = word.text.trim();
      if (text.isNotEmpty && !_leadingPunctuation.hasMatch(token)) {
        text.write(' ');
      }
      text.write(token);
    }
    phrases.add(
      Caption(
        start: current.first.start,
        end: current.last.end,
        text: text.toString(),
      ),
    );
    current.clear();
  }

  for (final word in words) {
    if (word.text.trim().isEmpty) continue;
    if (current.isNotEmpty) {
      final gap = word.start - current.last.end;
      final length = word.end - current.first.start;
      if (current.length >= maxWords ||
          length > maxLength ||
          gap >= pause ||
          _sentenceEnd.hasMatch(current.last.text.trim())) {
        flush();
      }
    }
    current.add(word);
  }
  flush();
  return phrases;
}

/// The caption on screen at [position], if any.
Caption? captionAt(List<Caption> captions, Duration position) {
  for (final caption in captions) {
    if (position >= caption.start && position < caption.end) return caption;
  }
  return null;
}

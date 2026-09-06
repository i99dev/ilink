import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/voice/ondevice/number_words.dart';

/// The on-device number grammar enumerates spoken setpoints, so the integer →
/// English-word rendering must be exact (and space-joined, since Vosk emits
/// separate tokens and `normalizePhrase` collapses whitespace anyway).
void main() {
  group('englishNumberWord', () {
    test('ones (0–19) are single words', () {
      expect(englishNumberWord(0), 'zero');
      expect(englishNumberWord(3), 'three');
      expect(englishNumberWord(7), 'seven');
      expect(englishNumberWord(16), 'sixteen');
      expect(englishNumberWord(19), 'nineteen');
    });

    test('round tens are single words', () {
      expect(englishNumberWord(20), 'twenty');
      expect(englishNumberWord(30), 'thirty');
      expect(englishNumberWord(90), 'ninety');
    });

    test('compound tens are space-joined (not hyphenated)', () {
      expect(englishNumberWord(21), 'twenty one');
      expect(englishNumberWord(22), 'twenty two');
      expect(englishNumberWord(32), 'thirty two');
      expect(englishNumberWord(99), 'ninety nine');
    });

    test('out of range → null', () {
      expect(englishNumberWord(-1), isNull);
      expect(englishNumberWord(100), isNull);
    });

    test('covers every current setpoint value without gaps', () {
      // temp 16–32 and fan 0–7 must all render.
      for (var n = 0; n <= 32; n++) {
        expect(englishNumberWord(n), isNotNull, reason: 'missing word for $n');
      }
    });
  });

  group('arabicNumberWord', () {
    test('ones + teens', () {
      expect(arabicNumberWord(0), 'صفر');
      expect(arabicNumberWord(3), 'ثلاثة');
      expect(arabicNumberWord(7), 'سبعة');
      expect(arabicNumberWord(10), 'عشرة');
      expect(arabicNumberWord(16), 'ستة عشر');
      expect(arabicNumberWord(19), 'تسعة عشر');
    });

    test('round tens + compounds use "<unit> و<tens>"', () {
      expect(arabicNumberWord(20), 'عشرون');
      expect(arabicNumberWord(22), 'اثنان وعشرون');
      expect(arabicNumberWord(30), 'ثلاثون');
      expect(arabicNumberWord(32), 'اثنان وثلاثون');
    });

    test('out of range → null', () {
      expect(arabicNumberWord(-1), isNull);
      expect(arabicNumberWord(100), isNull);
    });

    test('covers every current setpoint value without gaps', () {
      for (var n = 0; n <= 32; n++) {
        expect(arabicNumberWord(n), isNotNull, reason: 'missing word for $n');
      }
    });
  });
}

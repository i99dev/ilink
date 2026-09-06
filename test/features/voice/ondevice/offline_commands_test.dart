import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/_car_domain/command/command.dart';
import 'package:ilink/features/voice/ondevice/offline_commands.dart';

/// The "?" help sheet must list exactly what the on-device grammar can
/// dispatch — these guard that derivation against the real registry.
void main() {
  group('offlineVoiceCommands', () {
    final sections = offlineVoiceCommands();

    OfflineCommand? find(String label) {
      for (final s in sections) {
        for (final c in s.commands) {
          if (c.label == label) return c;
        }
      }
      return null;
    }

    test('produces non-empty, alphabetised category sections', () {
      expect(sections, isNotEmpty);
      for (final s in sections) {
        expect(s.commands, isNotEmpty, reason: '${s.title} is empty');
        final labels = s.commands.map((c) => c.label).toList();
        expect(labels, orderedEquals([...labels]..sort()));
        for (final c in s.commands) {
          expect(c.examples, isNotEmpty);
          expect(c.examples.length, lessThanOrEqualTo(2));
        }
      }
    });

    test('voiceHidden commands (radio) never surface', () {
      // radio.* is voiceHidden → excluded from the grammar → absent here.
      final hasRadioCategory = sections.any(
        (s) => s.category == CommandCategory.radio,
      );
      expect(hasRadioCategory, isFalse);
    });

    test('on-device-excluded commands (lights + stop) never surface', () {
      // The whole light category is off the fast-path.
      expect(sections.any((s) => s.category == CommandCategory.light), isFalse);
      // No `*.stop` command (window/hood/sunroof) appears in any section.
      final hasStop = sections
          .expand((s) => s.commands)
          .any((c) => c.examples.any((e) => e.contains('stop')));
      expect(hasStop, isFalse);
    });

    test('a door command is listed under Doors with an example', () {
      final lock = find('Lock');
      expect(lock, isNotNull);
      expect(lock!.category, CommandCategory.door);
      expect(lock.examples.first, contains('lock'));
    });

    test('numeric setpoint collapses to ONE example at the default value', () {
      final temp = find('Climate temp');
      expect(temp, isNotNull);
      // Whole 16-32 range → a single representative, at the 22°C default.
      expect(temp!.examples, hasLength(1));
      expect(temp.examples.first, contains('twenty two'));
    });

    test('on/off command shows both directions', () {
      final power = find('Climate power');
      expect(power, isNotNull);
      expect(power!.examples, hasLength(2));
      expect(power.examples.any((e) => e.contains('on')), isTrue);
      expect(power.examples.any((e) => e.contains('off')), isTrue);
    });
  });

  group('offlineVoiceCommands (Arabic)', () {
    final sections = offlineVoiceCommands(langCode: 'ar');

    OfflineCommand? find(String label) {
      for (final s in sections) {
        for (final c in s.commands) {
          if (c.label == label) return c;
        }
      }
      return null;
    }

    test('section titles are localized to Arabic', () {
      final climate = sections.firstWhere(
        (s) => s.category == CommandCategory.climate,
      );
      expect(climate.title, 'التكييف');
    });

    test('command labels + examples are Arabic', () {
      final lock = find('قفل الأبواب');
      expect(lock, isNotNull);
      expect(lock!.category, CommandCategory.door);
      expect(lock.examples.first, contains('اقفل'));
    });

    test('numeric setpoint is Arabic + collapses to the default value', () {
      final temp = find('درجة الحرارة');
      expect(temp, isNotNull);
      expect(temp!.examples, hasLength(1));
      expect(temp.examples.first, contains('وعشرون')); // 22 → اثنان وعشرون
    });

    test('lights + stop excluded in Arabic too', () {
      expect(sections.any((s) => s.category == CommandCategory.light), isFalse);
    });
  });
}

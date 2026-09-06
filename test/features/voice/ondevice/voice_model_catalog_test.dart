import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/_car_domain/command/command.dart';
import 'package:ilink/features/voice/ondevice/command_phrases.dart';
import 'package:ilink/features/voice/ondevice/voice_grammar.dart';
import 'package:ilink/features/voice/ondevice/voice_model_catalog.dart';

CarCommand _cmd(String id, String label) => CarCommand(
  id: id,
  label: label,
  icon: Icons.abc,
  color: const Color(0xFF000000),
  category: CommandCategory.door,
);

void main() {
  group('catalog', () {
    test('every entry is well-formed (our CDN zip + lang + size)', () {
      expect(voiceModelCatalog, isNotEmpty);
      for (final e in voiceModelCatalog) {
        expect(e.langCode, isNotEmpty);
        expect(e.file, isNotEmpty);
        // url is composed from the single CDN base + file, and is a zip.
        expect(e.url, startsWith(kVoiceModelCdnBase));
        expect(e.url, endsWith('.zip'));
        expect(e.url, endsWith(e.file));
        expect(e.sizeMb, greaterThan(0));
        expect(e.version, isNotEmpty);
      }
    });

    test('langCodes are unique', () {
      final codes = voiceModelCatalog.map((e) => e.langCode).toList();
      expect(codes.toSet().length, codes.length);
    });

    test('lookup by tag', () {
      expect(voiceModelFor('ar')?.nativeLabel, 'العربية');
      expect(voiceModelFor('does-not-exist'), isNull);
    });

    test('every primary engine is Vosk; only Arabic carries a fallback', () {
      for (final e in voiceModelCatalog) {
        expect(
          e.engine,
          VoiceEngine.vosk,
          reason: '${e.langCode} primary should be Vosk',
        );
        if (e.langCode != 'ar') {
          expect(e.fallback, isNull, reason: '${e.langCode} needs no fallback');
        }
      }
    });

    test('Arabic is two-tier: Vosk primary + Moonshine fallback', () {
      final ar = voiceModelFor('ar')!;
      // Primary = the Vosk grammar fast-path (100% on exact commands).
      expect(ar.engine, VoiceEngine.vosk);
      expect(ar.file, 'vosk-model-small-ar-0.3.zip');
      expect(ar.version, 'ar-0.3');
      // Fallback = Moonshine for dialect / out-of-grammar. The bundle also
      // carries the sherpa/onnx .so stripped from the APK, so file + version
      // are the `-libs` variant and the size jumped to ~141 MB.
      final fb = ar.fallback;
      expect(fb, isNotNull);
      expect(fb!.engine, VoiceEngine.moonshine);
      expect(fb.file, 'moonshine-base-ar-libs-2026-06-26.zip');
      expect(fb.version, 'ar-moonshine-libs-2026-06-26');
      expect(
        fb.sizeMb,
        greaterThan(120),
        reason: 'bundle now includes ~31MB of .so',
      );
      expect(fb.url, startsWith(kVoiceModelCdnBase));
      expect(fb.url, endsWith('.zip'));
    });

    test('engine defaults to vosk and fallback to null when unspecified', () {
      const e = VoiceModelEntry(
        langCode: 'xx',
        label: 'X',
        nativeLabel: 'X',
        file: 'x.zip',
        sizeMb: 1,
        version: 'x-1',
      );
      expect(e.engine, VoiceEngine.vosk);
      expect(e.fallback, isNull);
    });

    test('command localization is derived + covers every catalog language', () {
      // The flag is no longer stored on the entry — it's derived from the
      // grammar that actually ships (isCommandLocalized). Every catalog
      // language now has a localized command set.
      for (final e in voiceModelCatalog) {
        expect(
          isCommandLocalized(e.langCode),
          isTrue,
          reason: '${e.langCode} should ship localized commands',
        );
      }
      // An unsupported language → wake-only fallback (commands to cloud AI).
      expect(isCommandLocalized('xx'), isFalse);
    });
  });

  group('language-aware grammar', () {
    final registry = {'door.lock': _cmd('door.lock', 'LOCK')};

    test('English: wake + localized commands', () {
      final g = VoiceGrammar.build(registry: registry, langCode: 'en-us');
      expect(g.wakePhrases, contains('hey byd'));
      expect(g.exact('lock the doors')?.commandId, 'door.lock');
    });

    test('Arabic: localized wake AND localized commands', () {
      final g = VoiceGrammar.build(registry: registry, langCode: 'ar');
      // Arabic wake present...
      expect(g.wakePhrases.any((w) => w.contains('بي')), isTrue);
      // ...and the Arabic command phrase resolves to the SAME canonical id
      // as English (intent defined once, surface translated per language).
      expect(g.exact('اقفل الأبواب')?.commandId, 'door.lock');
      // The English phrasing is NOT in the Arabic grammar.
      expect(g.exact('lock the doors'), isNull);
    });

    test('unsupported language falls back to the English wake', () {
      final g = VoiceGrammar.build(registry: registry, langCode: 'xx');
      expect(g.wakePhrases, contains('hey byd'));
    });
  });
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/_car_domain/command/command.dart';
import 'package:ilink/features/_car_domain/command/registry.dart';
import 'package:ilink/features/voice/ondevice/command_phrases.dart';
import 'package:ilink/features/voice/ondevice/voice_grammar.dart';
import 'package:ilink/features/voice/ondevice/voice_model_catalog.dart';

/// Tiny in-memory registry so the machinery is tested deterministically,
/// independent of the real catalog's churn.
CarCommand _cmd(
  String id, {
  String? label,
  Map<String, String> params = const {},
  bool hidden = false,
}) => CarCommand(
  id: id,
  label: label ?? id,
  icon: Icons.abc,
  color: const Color(0xFF000000),
  category: CommandCategory.door,
  params: params,
  voiceHidden: hidden,
);

void main() {
  group('normalizePhrase', () {
    test('lowercases, strips punctuation, collapses whitespace', () {
      expect(normalizePhrase('  Lock THE  Doors!! '), 'lock the doors');
      expect(normalizePhrase('Open the trunk.'), 'open the trunk');
    });
    test('preserves unicode letters (Arabic)', () {
      expect(normalizePhrase('يا بي'), 'يا بي');
    });
    test('empty/punctuation-only collapses to empty', () {
      expect(normalizePhrase('  ...!! '), '');
    });
  });

  group('VoiceGrammar.build', () {
    test('auto-derives a phrase from the label of arg-free commands', () {
      final reg = {'door.lock': _cmd('door.lock', label: 'LOCK')};
      final g = VoiceGrammar.build(registry: reg, seeds: const []);
      expect(g.exact('lock')?.commandId, 'door.lock');
    });

    test('excludes arg-bearing commands from the v1 fast-path', () {
      final reg = {
        'climate.temp': _cmd('climate.temp', params: {'value': '16-32'}),
      };
      final g = VoiceGrammar.build(registry: reg, seeds: const []);
      expect(g.phraseCount, 0);
    });

    test('excludes voiceHidden commands (e.g. radio)', () {
      final reg = {
        'radio.pause': _cmd('radio.pause', label: 'PAUSE', hidden: true),
      };
      final g = VoiceGrammar.build(registry: reg, seeds: const []);
      expect(g.phraseCount, 0);
    });

    test('respects the routability filter (manifest parity)', () {
      final reg = {
        'door.lock': _cmd('door.lock', label: 'LOCK'),
        'door.unlock': _cmd('door.unlock', label: 'UNLOCK'),
      };
      final g = VoiceGrammar.build(
        registry: reg,
        seeds: const [],
        handles: (id) => id == 'door.lock', // only lock is routable
      );
      expect(g.exact('lock'), isNotNull);
      expect(g.exact('unlock'), isNull);
    });

    test('curated seeds augment auto phrases and bind to the command', () {
      final reg = {'door.lock': _cmd('door.lock', label: 'LOCK')};
      final g = VoiceGrammar.build(
        registry: reg,
        seeds: const [
          CommandPhraseSeed('door.lock', ['lock the doors', 'lock the car']),
        ],
      );
      expect(g.exact('lock')?.commandId, 'door.lock'); // auto
      expect(g.exact('lock the doors')?.commandId, 'door.lock'); // curated
      expect(g.exact('lock the car')?.commandId, 'door.lock');
    });

    test('drops seeds whose command id is not in the registry', () {
      final reg = {'door.lock': _cmd('door.lock', label: 'LOCK')};
      final g = VoiceGrammar.build(
        registry: reg,
        seeds: const [
          CommandPhraseSeed('door.ghost', ['phantom command']),
        ],
      );
      expect(g.exact('phantom command'), isNull);
    });

    test('vocabulary includes wake-word tokens', () {
      final reg = {'door.lock': _cmd('door.lock', label: 'LOCK')};
      final g = VoiceGrammar.build(registry: reg, seeds: const []);
      expect(g.vocabulary, containsAll(['hey', 'byd', 'lock']));
    });

    test('only local wake phrases are included in recognition grammar', () {
      final reg = {'door.lock': _cmd('door.lock', label: 'LOCK')};
      final g = VoiceGrammar.build(registry: reg, seeds: const []);
      expect(g.wakePhrases, contains('hey byd'));
      final list = (jsonDecode(g.toVoskGrammarJson()) as List).cast<String>();
      expect(list, isNot(contains('hey ai')));
      expect(g.vocabulary, containsAll(['hey', 'byd']));
      expect(g.vocabulary, isNot(contains('ai')));
    });

    test('extraWakePhrases are ADDITIVE to the built-in default', () {
      final reg = {'door.lock': _cmd('door.lock', label: 'LOCK')};
      final g = VoiceGrammar.build(
        registry: reg,
        seeds: const [],
        extraWakePhrases: const ['Marhaba BYD'],
      );
      // Custom phrase is present (normalized)…
      expect(g.wakePhrases, contains('marhaba byd'));
      // …and the built-in default still works (never replaced).
      expect(g.wakePhrases, contains('hey byd'));
      expect(g.vocabulary, containsAll(['marhaba', 'hey', 'byd']));
    });

    test('extraWakePhrases dedupe against the default + drop empties', () {
      final reg = {'door.lock': _cmd('door.lock', label: 'LOCK')};
      final g = VoiceGrammar.build(
        registry: reg,
        seeds: const [],
        // Re-states the default + a punctuation-only blank.
        extraWakePhrases: const ['Hey BYD', '  !!  '],
      );
      expect(g.wakePhrases.where((w) => w == 'hey byd').length, 1);
      expect(g.wakePhrases, isNot(contains('')));
    });

    test('a non-Latin extra wake phrase normalizes + survives', () {
      final reg = {'door.lock': _cmd('door.lock', label: 'LOCK')};
      final g = VoiceGrammar.build(
        registry: reg,
        seeds: const [],
        langCode: 'ar',
        extraWakePhrases: const ['مرحبا بايدي'],
      );
      expect(g.wakePhrases, contains('مرحبا بايدي'));
    });

    test('toVoskGrammarJson is sorted, deduped, and [unk]-terminated', () {
      final reg = {
        'door.lock': _cmd('door.lock', label: 'LOCK'),
        'door.unlock': _cmd('door.unlock', label: 'UNLOCK'),
      };
      final g = VoiceGrammar.build(registry: reg, seeds: const []);
      final list = (jsonDecode(g.toVoskGrammarJson()) as List).cast<String>();
      expect(list.last, '[unk]');
      expect(list, contains('hey byd'));
      expect(list, contains('lock'));
      final body = list.sublist(0, list.length - 1);
      final sorted = [...body]..sort();
      expect(body, sorted, reason: 'grammar order must be deterministic');
    });
  });

  // ── Parity against the REAL registry — the one-source-of-truth guard ──
  group('real registry parity', () {
    test('every curated seed id exists in the registry', () {
      for (final seed in commandVoicePhrases) {
        expect(
          commandRegistry.containsKey(seed.commandId),
          isTrue,
          reason: 'seed "${seed.commandId}" is not a registry command',
        );
      }
    });

    test('no curated seed targets a voiceHidden command', () {
      for (final seed in commandVoicePhrases) {
        expect(
          commandRegistry[seed.commandId]!.voiceHidden,
          isFalse,
          reason:
              '"${seed.commandId}" is voiceHidden — it must not enter the '
              'daemon-bound fast-path (route it via its subagent instead)',
        );
      }
    });

    test('curated seeds bake complete, valid args for their command', () {
      for (final seed in commandVoicePhrases) {
        final cmd = commandRegistry[seed.commandId]!;
        if (cmd.params.isEmpty) {
          // Arg-free command → the seed must carry no baked args.
          expect(
            seed.args,
            isEmpty,
            reason: 'arg-free "${seed.commandId}" must not carry baked args',
          );
        } else {
          // Parameterized → the seed MUST bake exactly the command's param
          // keys so the on-device dispatch is complete + valid (no missing
          // or unknown args). Today only {on: bool} toggles are seeded;
          // numeric params still route to the cloud AI (number grammar).
          expect(
            seed.args.keys.toSet(),
            cmd.params.keys.toSet(),
            reason:
                '"${seed.commandId}" seed must bake exactly its params '
                '${cmd.params.keys} (got ${seed.args.keys})',
          );
        }
      }
    });

    test('generated number seeds bake exactly {value} for a real command', () {
      expect(numberCommandSeeds, isNotEmpty);
      for (final seed in numberCommandSeeds) {
        final cmd = commandRegistry[seed.commandId];
        expect(cmd, isNotNull, reason: '"${seed.commandId}" not in registry');
        expect(cmd!.voiceHidden, isFalse);
        expect(
          seed.args.keys.toSet(),
          cmd.params.keys.toSet(),
          reason: '"${seed.commandId}" must bake exactly ${cmd.params.keys}',
        );
        expect(seed.args['value'], isA<int>());
      }
    });

    test('builds a non-empty grammar over the real registry', () {
      final g = VoiceGrammar.build(registry: commandRegistry);
      expect(g.phraseCount, greaterThan(0));
      // Curated door phrases resolve to the real ids.
      expect(g.exact('lock the doors')?.commandId, 'door.lock');
      expect(g.exact('open the trunk')?.commandId, 'door.trunk.open');
      // Window phrases route on-device (regression: these used to miss and
      // fall to the cloud LLM). A bare "the window" = the driver pane.
      expect(g.exact('open the window')?.commandId, 'window.fl.open');
      expect(g.exact('close the window')?.commandId, 'window.fl.close');
      expect(g.exact('open the passenger window')?.commandId, 'window.fr.open');
      // On/off toggles resolve to the real id WITH the baked direction arg.
      final acOn = g.exact('turn on the ac');
      expect(acOn?.commandId, 'climate.power');
      expect(acOn?.args, {'on': true});
      final acOff = g.exact('turn off the ac');
      expect(acOff?.commandId, 'climate.power');
      expect(acOff?.args, {'on': false});
      expect(g.exact('defrost the windshield')?.commandId, 'climate.defrost_f');
      expect(g.exact('max heat')?.commandId, 'climate.max_hot');
      expect(g.exact('turn off the fragrance')?.commandId, 'comfort.frag.off');
    });

    test('on-device-excluded commands never enter the fast-path', () {
      final g = VoiceGrammar.build(registry: commandRegistry);
      // `*.stop` — momentary stop has no working on-car wire action.
      expect(g.exact('stop the window'), isNull);
      expect(g.exact('stop the passenger window'), isNull);
      expect(g.exact('stop the hood'), isNull);
      // The whole light category is off the fast-path (not actuating on-car).
      expect(g.exact('turn on the headlights'), isNull);
      expect(g.exact('turn on the front fog lights'), isNull);
      expect(g.exact('left turn signal'), isNull);
      expect(g.exact('flash the lights'), isNull);
      expect(g.exact('find my car'), isNull);
      // hood.* doesn't actuate on-car; trunk only OPENS by voice.
      expect(g.exact('open the hood'), isNull);
      expect(g.exact('close the hood'), isNull);
      expect(g.exact('close the trunk'), isNull);
      expect(g.exact('open the trunk')?.commandId, 'door.trunk.open'); // kept
      // No surviving phrase resolves to an excluded id (auto OR curated).
      for (final p in g.phrases) {
        final cmd = commandRegistry[p.commandId]!;
        expect(
          isOnDeviceExcluded(p.commandId, cmd.category),
          isFalse,
          reason: '"${p.commandId}" is excluded but reachable via "${p.text}"',
        );
      }
    });

    test('isOnDeviceExcluded: stop ids + the light category', () {
      expect(
        isOnDeviceExcluded('window.fl.stop', CommandCategory.window),
        true,
      );
      expect(isOnDeviceExcluded('hood.stop', CommandCategory.door), true);
      expect(isOnDeviceExcluded('light.head', CommandCategory.light), true);
      expect(isOnDeviceExcluded('light.find_car', CommandCategory.light), true);
      // Kept on the fast-path.
      expect(
        isOnDeviceExcluded('window.fl.open', CommandCategory.window),
        false,
      );
      expect(isOnDeviceExcluded('door.lock', CommandCategory.door), false);
      expect(
        isOnDeviceExcluded('climate.temp', CommandCategory.climate),
        false,
      );
      // hood.* + trunk-close excluded; trunk-open kept.
      expect(isOnDeviceExcluded('hood.open', CommandCategory.door), true);
      expect(isOnDeviceExcluded('hood.close', CommandCategory.door), true);
      expect(
        isOnDeviceExcluded('door.trunk.close', CommandCategory.door),
        true,
      );
      expect(
        isOnDeviceExcluded('door.trunk.open', CommandCategory.door),
        false,
      );
    });

    test('numeric setpoints resolve on-device with the baked value arg', () {
      final g = VoiceGrammar.build(registry: commandRegistry);
      // Temperature — multiple natural phrasings land the same value.
      final temp = g.exact('set the temperature to twenty two');
      expect(temp?.commandId, 'climate.temp');
      expect(temp?.args, {'value': 22});
      expect(g.exact('set the temp to thirty')?.args, {'value': 30});
      expect(g.exact('twenty degrees')?.commandId, 'climate.temp');
      expect(g.exact('twenty degrees')?.args, {'value': 20});
      // Fan speed — 0..7, including the off endpoint.
      final fan = g.exact('fan speed three');
      expect(fan?.commandId, 'climate.fan');
      expect(fan?.args, {'value': 3});
      expect(g.exact('set the fan to zero')?.args, {'value': 0});
      expect(g.exact('set the fan speed to seven')?.args, {'value': 7});
      // Out-of-range values are never enumerated → clean miss → cloud.
      expect(g.exact('set the temperature to forty'), isNull);
    });
  });

  group('multi-language command grammar', () {
    test('every core intent matches an English canonical (id, args) pair', () {
      // Drift guard: localized phrasings may only translate intents that the
      // English reference set already defines — never invent a binding.
      final canonical = {
        for (final s in commandVoicePhrases) '${s.commandId}|${s.args}',
      };
      for (final entry in coreIntents.entries) {
        final key = '${entry.value.commandId}|${entry.value.args}';
        expect(
          canonical.contains(key),
          isTrue,
          reason:
              'core intent "${entry.key}" (${entry.value.commandId} '
              '${entry.value.args}) has no English canonical seed',
        );
      }
    });

    test('every catalog language builds a non-empty command grammar', () {
      for (final e in voiceModelCatalog) {
        final g = VoiceGrammar.build(
          registry: commandRegistry,
          langCode: e.langCode,
        );
        expect(
          g.phraseCount,
          greaterThan(0),
          reason: '${e.langCode} grammar is empty',
        );
        expect(g.wakePhrases, isNotEmpty, reason: '${e.langCode} has no wake');
        expect(
          isCommandLocalized(e.langCode),
          isTrue,
          reason: '${e.langCode} should be command-localized',
        );
      }
    });

    test('every catalog language reaches FULL command coverage', () {
      // The non-excluded command set every supported language must dispatch
      // on-device (parity with English) — guards that a language isn't stuck
      // on the old reduced core.
      const required = {
        'door.lock',
        'door.unlock',
        'door.trunk.open',
        'window.fl.open',
        'window.fl.close',
        'window.fr.open',
        'window.fr.close',
        'window.rl.open',
        'window.rl.close',
        'window.rr.open',
        'window.rr.close',
        'climate.power',
        'climate.defrost_f',
        'climate.defrost_r',
        'climate.max_hot',
        'climate.max_cool',
        'climate.compressor',
        'climate.temp',
        'climate.fan',
        'comfort.frag.off',
      };
      for (final e in voiceModelCatalog) {
        final ids = commandSeedsByLang[e.langCode]!
            .map((s) => s.commandId)
            .toSet();
        expect(
          required.difference(ids),
          isEmpty,
          reason: '${e.langCode} is missing ${required.difference(ids)}',
        );
      }
    });

    test('every catalog language has on-device numeric setpoints', () {
      for (final e in voiceModelCatalog) {
        final seeds = numberSeedsByLang[e.langCode];
        expect(seeds, isNotNull, reason: '${e.langCode} has no number seeds');
        final ids = seeds!.map((s) => s.commandId).toSet();
        expect(ids, containsAll(['climate.temp', 'climate.fan']));
      }
    });

    test('every localized seed binds to a routable, non-hidden command', () {
      for (final entry in commandSeedsByLang.entries) {
        for (final seed in entry.value) {
          final cmd = commandRegistry[seed.commandId];
          expect(
            cmd,
            isNotNull,
            reason: '${entry.key}: "${seed.commandId}" not in registry',
          );
          expect(
            cmd!.voiceHidden,
            isFalse,
            reason: '${entry.key}: "${seed.commandId}" is voiceHidden',
          );
        }
      }
    });

    test('Arabic resolves localized phrases to the canonical id + args', () {
      final g = VoiceGrammar.build(registry: commandRegistry, langCode: 'ar');
      expect(g.exact('اقفل الأبواب')?.commandId, 'door.lock');
      final acOn = g.exact('شغل المكيف');
      expect(acOn?.commandId, 'climate.power');
      expect(acOn?.args, {'on': true});
      expect(g.exact('افتح النافذة')?.commandId, 'window.fl.open');
    });

    test('Arabic reaches FULL command parity (not just the old core)', () {
      final g = VoiceGrammar.build(registry: commandRegistry, langCode: 'ar');
      // Per-pane windows (passenger + rear).
      expect(g.exact('افتح نافذة الراكب')?.commandId, 'window.fr.open');
      expect(
        g.exact('اغلق النافذة الخلفية اليمنى')?.commandId,
        'window.rr.close',
      );
      // Climate toggles with baked direction.
      final acOff = g.exact('اطفئ المكيف');
      expect(acOff?.commandId, 'climate.power');
      expect(acOff?.args, {'on': false});
      expect(g.exact('اقصى تبريد')?.commandId, 'climate.max_cool');
      expect(g.exact('شغل الكمبروسر')?.commandId, 'climate.compressor');
      // Comfort.
      expect(g.exact('اطفئ المعطر')?.commandId, 'comfort.frag.off');
      // Numeric setpoints in Arabic — temp + fan with baked value.
      final temp = g.exact('اضبط الحرارة على اثنان وعشرون');
      expect(temp?.commandId, 'climate.temp');
      expect(temp?.args, {'value': 22});
      final fan = g.exact('سرعة المروحة ثلاثة');
      expect(fan?.commandId, 'climate.fan');
      expect(fan?.args, {'value': 3});
    });

    test('Arabic excludes the same families English does (lights + stop)', () {
      final g = VoiceGrammar.build(registry: commandRegistry, langCode: 'ar');
      expect(g.exact('شغل الأضواء'), isNull); // lights excluded
      expect(g.exact('وقف النافذة'), isNull); // *.stop excluded
      for (final p in g.phrases) {
        final cmd = commandRegistry[p.commandId]!;
        expect(isOnDeviceExcluded(p.commandId, cmd.category), isFalse);
      }
    });
  });
}

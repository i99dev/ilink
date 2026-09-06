import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/_car_domain/command/command.dart';
import 'package:ilink/features/voice/ondevice/command_phrases.dart';
import 'package:ilink/features/voice/ondevice/local_intent_matcher.dart';
import 'package:ilink/features/voice/ondevice/ondevice_voice_router.dart';
import 'package:ilink/features/voice/ondevice/voice_grammar.dart';

CarCommand _cmd(String id, String label) => CarCommand(
  id: id,
  label: label,
  icon: Icons.abc,
  color: const Color(0xFF000000),
  category: CommandCategory.door,
);

OnDeviceVoiceRouter _router() {
  final registry = {'door.lock': _cmd('door.lock', 'LOCK')};
  const seeds = [
    CommandPhraseSeed('door.lock', ['lock the doors']),
  ];
  final grammar = VoiceGrammar.build(registry: registry, seeds: seeds);
  return OnDeviceVoiceRouter(grammar, LocalIntentMatcher(grammar));
}

void main() {
  final r = _router();

  test('no wake word → ignore (wake-gated; never act on overheard speech)', () {
    expect(r.decide('lock the doors'), isA<OnDeviceIgnore>());
    expect(r.decide('what is the weather'), isA<OnDeviceIgnore>());
    expect(r.decide(''), isA<OnDeviceIgnore>());
  });

  test('bare wake → open assistant turn with no query', () {
    final d = r.decide('hey byd');
    expect(d, isA<OnDeviceWakeTurn>());
    expect((d as OnDeviceWakeTurn).spokenQuery, isNull);
  });

  test('wake + local command → instant local dispatch', () {
    final d = r.decide('hey byd lock the doors');
    expect(d, isA<OnDeviceLocalCommand>());
    expect((d as OnDeviceLocalCommand).hit.commandId, 'door.lock');
  });

  test('wake + open-ended request → cloud turn seeded with the query', () {
    final d = r.decide('hey byd what time is it');
    expect(d, isA<OnDeviceWakeTurn>());
    expect((d as OnDeviceWakeTurn).spokenQuery, 'what time is it');
  });

  test('wake + filler then command still dispatches locally', () {
    final d = r.decide('Hey BYD, please lock the doors');
    expect(d, isA<OnDeviceLocalCommand>());
    expect((d as OnDeviceLocalCommand).hit.commandId, 'door.lock');
  });

  group('two-wake split — "Hey AI" routes to the cloud deterministically', () {
    test('bare "hey ai" → AI wake, no query', () {
      final d = r.decide('hey ai');
      expect(d, isA<OnDeviceIgnore>());
    });

    test('"hey ai <request>" → AI wake carrying the remainder', () {
      final d = r.decide('hey ai what time is it');
      expect(d, isA<OnDeviceIgnore>());
    });

    test('"hey ai <command words>" still goes to the AI, NOT offline', () {
      // The driver chose the AI by wake word — even command-like words route
      // to the cloud (deterministic engine split, no intent guessing).
      final d = r.decide('hey ai lock the doors');
      expect(d, isA<OnDeviceIgnore>());
    });

    test('"hey byd <command>" stays offline (unchanged)', () {
      final d = r.decide('hey byd lock the doors');
      expect(d, isA<OnDeviceLocalCommand>());
    });
  });

  group('decideManual (push-to-talk — no wake word required)', () {
    test('a command dispatches locally without any wake word', () {
      final d = r.decideManual('lock the doors');
      expect(d, isA<OnDeviceLocalCommand>());
      expect((d as OnDeviceLocalCommand).hit.commandId, 'door.lock');
    });

    test('fillers are tolerated', () {
      final d = r.decideManual('please lock the doors');
      expect(d, isA<OnDeviceLocalCommand>());
      expect((d as OnDeviceLocalCommand).hit.commandId, 'door.lock');
    });

    test('non-command → escalate to cloud, carrying the transcript', () {
      final d = r.decideManual('what is the weather');
      expect(d, isA<OnDeviceWakeTurn>());
      expect((d as OnDeviceWakeTurn).spokenQuery, 'what is the weather');
    });

    test('empty transcript → escalate with no query', () {
      final d = r.decideManual('');
      expect(d, isA<OnDeviceWakeTurn>());
      expect((d as OnDeviceWakeTurn).spokenQuery, isNull);
    });
  });
}

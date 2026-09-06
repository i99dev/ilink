import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/_car_domain/command/command.dart';
import 'package:ilink/features/voice/ondevice/command_phrases.dart';
import 'package:ilink/features/voice/ondevice/local_intent_matcher.dart';
import 'package:ilink/features/voice/ondevice/voice_grammar.dart';

CarCommand _cmd(String id, String label) => CarCommand(
  id: id,
  label: label,
  icon: Icons.abc,
  color: const Color(0xFF000000),
  category: CommandCategory.door,
);

LocalIntentMatcher _matcher() {
  final registry = {
    'door.lock': _cmd('door.lock', 'LOCK'),
    'door.unlock': _cmd('door.unlock', 'UNLOCK'),
    'door.trunk.open': _cmd('door.trunk.open', 'TRUNK OPEN'),
  };
  const seeds = [
    CommandPhraseSeed('door.lock', ['lock the doors', 'lock the car']),
    CommandPhraseSeed('door.unlock', ['unlock the doors']),
    CommandPhraseSeed('door.trunk.open', ['open the trunk', 'pop the trunk']),
  ];
  return LocalIntentMatcher(
    VoiceGrammar.build(registry: registry, seeds: seeds),
  );
}

void main() {
  final m = _matcher();

  test('exact phrase resolves with high confidence', () {
    final hit = m.match('lock the doors');
    expect(hit, isNotNull);
    expect(hit!.commandId, 'door.lock');
    expect(hit.exact, isTrue);
  });

  test('case and punctuation are ignored', () {
    expect(m.match('Lock The Doors!!')?.commandId, 'door.lock');
  });

  test('leading wake word is stripped', () {
    expect(m.match('hey byd lock the doors')?.commandId, 'door.lock');
    expect(m.match('Hey BYD, open the trunk')?.commandId, 'door.trunk.open');
  });

  test('bare wake word returns null (arm listening, do not dispatch)', () {
    expect(m.match('hey byd'), isNull);
  });

  test('conversational fillers are tolerated via token-subset fallback', () {
    final hit = m.match('could you please lock the doors for me');
    expect(hit, isNotNull);
    expect(hit!.commandId, 'door.lock');
    expect(hit.exact, isFalse); // resolved by fallback, not exact
  });

  test('more specific phrase wins over the bare label', () {
    // "lock" (auto label) and "lock the doors" (curated) both map to
    // door.lock; the specific one is chosen, and "unlock" is not confused.
    expect(m.match('please lock the doors')?.commandId, 'door.lock');
    expect(m.match('unlock the doors')?.commandId, 'door.unlock');
  });

  test('out-of-grammar speech returns null (→ cloud LLM fallback)', () {
    expect(m.match('what is the meaning of life'), isNull);
    expect(m.match('play some jazz from france'), isNull);
    expect(m.match(''), isNull);
  });

  test('auto label phrase resolves on its own', () {
    expect(m.match('lock')?.commandId, 'door.lock');
  });
}

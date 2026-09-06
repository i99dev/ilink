import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Voice entry points must use the local access and microphone gates.
/// The on-device helper checks both before calling the lifecycle controller;
/// the controller also enforces enablement and microphone permission itself.
void main() {
  const projectRoot = 'lib';
  const exemptPaths = <String>{
    // The gate itself.
    'lib/features/voice/state/voice_access_gate.dart',
    // The voice controller implementation. Hardware-key branch calls
    // start() after canStartVoice(ref) returns true.
    'lib/features/voice/state/voice_controller.dart',
    // startVoiceCommandOnly checks local access and microphone permission.
    'lib/features/voice/ondevice/ondevice_voice_controller.dart',
  };

  test('gate paths normalize across Windows and POSIX', () {
    const expected =
        'lib/features/voice/ondevice/ondevice_voice_controller.dart';
    expect(
      _normalizePath(
        r'lib\features\voice\ondevice\ondevice_voice_controller.dart',
      ),
      expected,
    );
    expect(_normalizePath('./$expected'), expected);
  });

  test('no direct voiceControllerProvider.start() outside the gate', () async {
    final offenders = await _scan(
      projectRoot: projectRoot,
      exemptPaths: exemptPaths,
      // Only matches `.start(`, not `.stop(` — uninstall-style
      // teardown calls don't need the gate.
      pattern: RegExp(
        r'voiceControllerProvider\.notifier\)?\s*\.\s*start\s*\(',
      ),
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'Direct voiceControllerProvider.notifier.start() detected.\n'
          'Use startVoiceWithGate(context, ref) (UI surface) or\n'
          'canStartVoice(ref) + start() (no-context handler) instead.\n'
          'See lib/features/voice/state/voice_access_gate.dart.\n\n'
          'Offenders:\n${offenders.join('\n')}',
    );
  });
}

Future<List<String>> _scan({
  required String projectRoot,
  required Set<String> exemptPaths,
  required RegExp pattern,
}) async {
  final dir = Directory(projectRoot);
  if (!dir.existsSync()) fail('lib/ not found — run from project root');
  final offenders = <String>[];
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    if (!entity.path.endsWith('.dart')) continue;
    // Normalize to forward slashes so the exempt set (`lib/...`) matches
    // on Windows (where Directory.list yields `lib\...`).
    final rel = _normalizePath(entity.path);
    if (exemptPaths.contains(rel)) continue;
    final source = await entity.readAsString();
    for (final (i, line) in source.split('\n').indexed) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('//') ||
          trimmed.startsWith('///') ||
          trimmed.startsWith('*')) {
        continue;
      }
      if (pattern.hasMatch(line)) {
        offenders.add('${entity.path}:${i + 1}: ${line.trim()}');
      }
    }
  }
  return offenders;
}

String _normalizePath(String path) =>
    path.replaceAll(RegExp(r'[\\/]+'), '/').replaceFirst(RegExp(r'^\./'), '');

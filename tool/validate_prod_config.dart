/// Validates ``.github/environments/prod.json`` against the dart-define
/// keys that ``lib/kernel/config/app_config.dart`` actually reads.
///
/// The original CI step used ``flutter analyze --dart-define-from-file=…``,
/// but that flag is only honored by ``flutter build`` / ``flutter run``;
/// ``analyze`` silently rejected it (exit 64). Switching to a tiny Dart
/// validator preserves the original intent — "would prod.json load
/// cleanly into AppConfig.fromEnvironment?" — without paying the
/// 4-minute price of an APK build on every PR.
///
/// Catches:
///   1. Malformed JSON (parse exception → exit 1).
///   2. Missing required keys.
///   3. Type drift (e.g. ``DAEMON_PORT`` accidentally quoted as a string).
///
/// Does NOT catch logical issues like an unreachable backend URL —
/// ``DEFAULT_BACKEND_URL`` is intentionally NOT in prod.json (it's a
/// per-environment GitHub secret), so the validator explicitly skips it.
library;

// ``print`` is the right tool here — this is a CLI utility whose
// success/failure stream IS the user-facing output.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const _path = 'config/prod.json';

// Keys + expected JSON types. Mirrors the ``*.fromEnvironment`` calls
// in ``app_config.dart``. Update this list when AppConfig grows a
// new compile-time knob.
const _required = <String, Type>{
  'APP_ENV': String,
  'MOCK_CAR': bool,
  'LOG_LEVEL': String,
  'DAEMON_HOST': String,
  'DAEMON_PORT': int,
  'ADBD_PORT': int,
};

void main() {
  final file = File(_path);
  if (!file.existsSync()) {
    stderr.writeln('validate_prod_config: $_path not found');
    exit(1);
  }

  late Map<String, dynamic> json;
  try {
    json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  } on FormatException catch (e) {
    stderr.writeln('validate_prod_config: $_path is not valid JSON — $e');
    exit(1);
  }

  final problems = <String>[];
  for (final entry in _required.entries) {
    final key = entry.key;
    final type = entry.value;
    if (!json.containsKey(key)) {
      problems.add('missing key: $key');
      continue;
    }
    final value = json[key];
    final ok = switch (type) {
      const (String) => value is String,
      const (bool) => value is bool,
      const (int) => value is int,
      _ => false,
    };
    if (!ok) {
      problems.add(
        'wrong type for $key: expected $type, got ${value.runtimeType}',
      );
    }
  }

  if (problems.isNotEmpty) {
    stderr.writeln('validate_prod_config: $_path has issues:');
    for (final p in problems) {
      stderr.writeln('  - $p');
    }
    exit(1);
  }

  print(
    'validate_prod_config: $_path ok '
    '(${_required.length} required keys present and well-typed).',
  );
}

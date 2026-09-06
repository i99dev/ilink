/// Derives the Android `versionCode` from the release `versionName` and writes
/// it back into `pubspec.yaml`.
///
/// release-please bumps the versionName but leaves the `+<code>` build metadata
/// untouched, so without this step every release ships the same versionCode.
/// Android refuses an update whose versionCode did not increase, and
/// `scripts/ci/check-release-version.py` fails the build for the same reason —
/// so the second release could never go out.
///
/// The code is a pure function of the versionName:
///
///     major * 1000000 + minor * 1000 + patch
///
/// `3.22.0` → 3022000, `3.23.0` → 3023000, `4.0.0` → 4000000. It rises with
/// SemVer, is reproducible from the tag alone with no stored state, and stays
/// well under Android's 2100000000 ceiling.
///
/// A pre-release suffix (`3.22.0-b`) does not affect the code: `-b` marks the
/// whole line as beta rather than distinguishing builds, and release-please
/// never emits the same versionName twice.
library;

import 'dart:io';

const int maxAndroidVersionCode = 2100000000;

final RegExp versionLine = RegExp(
  r'^version:[ \t]*(\S+)[ \t]*$',
  multiLine: true,
);

/// Thrown for a versionName this scheme cannot order.
class VersionCodeError implements Exception {
  VersionCodeError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `3.22.0-b+10000` → 3022000. Build metadata and pre-release suffix ignored.
int deriveVersionCode(String versionName) {
  final core = versionName.split('+').first.split('-').first;
  final parts = core.split('.');
  if (parts.length != 3 ||
      parts.any((p) => p.isEmpty || int.tryParse(p) == null)) {
    throw VersionCodeError(
      'versionName "$versionName" is not <major>.<minor>.<patch>',
    );
  }
  final major = int.parse(parts[0]);
  final minor = int.parse(parts[1]);
  final patch = int.parse(parts[2]);
  if (minor >= 1000 || patch >= 1000) {
    throw VersionCodeError(
      'minor and patch must stay under 1000 to keep versionCode ordered: '
      '"$versionName"',
    );
  }
  final code = major * 1000000 + minor * 1000 + patch;
  if (code <= 0 || code > maxAndroidVersionCode) {
    throw VersionCodeError(
      'derived versionCode $code is outside Android range',
    );
  }
  return code;
}

/// Returns the rewritten pubspec content, or null when it is already correct.
String? applyVersionCode(String pubspec) {
  final match = versionLine.firstMatch(pubspec);
  if (match == null) {
    throw VersionCodeError('pubspec.yaml has no version: line');
  }
  final raw = match.group(1)!;
  final name = raw.split('+').first;
  final replacement = 'version: $name+${deriveVersionCode(name)}';
  if (match.group(0) == replacement) return null;
  return pubspec.replaceRange(match.start, match.end, replacement);
}

void main() {
  final file = File('pubspec.yaml');
  final original = file.readAsStringSync();
  final String? updated;
  try {
    updated = applyVersionCode(original);
  } on VersionCodeError catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
  final name = versionLine
      .firstMatch(updated ?? original)!
      .group(1)!
      .split('+')
      .first;
  final code = deriveVersionCode(name);
  if (updated != null) {
    file.writeAsStringSync(updated);
    stdout.writeln('set versionCode -> $name+$code');
  } else {
    stdout.writeln('versionCode already correct: $name+$code');
  }
  // Consumed by later workflow steps.
  final env = Platform.environment['GITHUB_ENV'];
  if (env != null && env.isNotEmpty) {
    File(env).writeAsStringSync(
      'RESOLVED_VERSION_NAME=$name\nRESOLVED_VERSION_CODE=$code\n',
      mode: FileMode.append,
    );
  }
}

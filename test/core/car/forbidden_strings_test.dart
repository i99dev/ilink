import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CI gate: reverse-engineered BYD constants (hex feature IDs, AIDL
/// descriptors, system-service names, reflection class names) must live
/// only in the known-boundary files listed in [_allowlistedPaths].
/// Anywhere else — Dart `lib/`, Kotlin `android/**`, test fixtures —
/// must stay clean. When the proto-encrypted CarTable lands (Phase 2
/// infrastructure), the allowlist shrinks to just the asset + the
/// loader; this test is the regression fence that keeps the identifier
/// blast radius from growing in the meantime.
///
/// Add an entry to [_allowlistedPaths] only after writing a comment in
/// the file explaining why the constants can't move yet (and a link back
/// to the plan step that'll retire them).
void main() {
  group('forbidden-string CI gate', () {
    final root = Directory.current;

    // Files where reverse-engineered constants are still unavoidable.
    // Every entry is a relative path from the dash/ root (tests run with
    // CWD == dash/). The encrypted asset (.secrets/car_table/parts/*.textproto
    // → assets/car_table.pb.enc) is the SoT for feature IDs; everything
    // else must stay clean.
    const allowlistedPaths = <String>{
      // Status-read feature IDs — proto StatusKey absorbs these.
      'android/app/src/main/kotlin/com/i99dev/ilink/car/AutoFeatureService.kt',
      // AIDL descriptors + Parcel transaction codes — proto BinderRoute.
      'android/app/src/main/kotlin/com/i99dev/ilink/car/AcFeatureService.kt',
      // Identity probe — harmless literal, small surface.
      'android/app/src/main/kotlin/com/i99dev/ilink/car/CarIdentity.kt',
      // getSystemService("auto") reflection — moves into NDK module (Phase 3).
      'android/app/src/main/java/com/i99dev/ilink/helper/DashDaemon.java',
      // ADB wire-protocol magic numbers (CMD_CLSE / CMD_SYNC etc.) — not
      // BYD-related; shared with the upstream open ADB client.
      'android/app/src/main/kotlin/com/i99dev/ilink/adb/AdbProtocol.kt',
      // Reflection-resolved BYD feature catalog — by definition has to
      // load the framework class by its package name. This is the
      // single place that names `android.hardware.bydauto`; every
      // other consumer of feature IDs goes through this catalog.
      'android/app/src/main/kotlin/com/i99dev/ilink/car/BydAutoFeatureIdsCatalog.kt',
      // In-app push device — extends `android.hardware.bydauto.AbsBYDAutoDevice`
      // by inheritance; the package name has to appear in source. Sole
      // file that reaches the framework class directly for push registration.
      'android/app/src/main/java/com/i99dev/ilink/helper/BydPushDevice.java',
      // BYD framework stub — local-only compile shim that mirrors the
      // framework API surface so the build compiles against a fake.
      // Lives under `byd-stub/` and is never shipped in the APK.
      'android/byd-stub/src/main/java/android/hardware/bydauto/AbsBYDAutoDevice.java',
      // Cluster-app patcher manifest editor — pins AOSP `android:*` attribute
      // resource ids (e.g. 0x010104f6 = resizeableActivity) that ARSCLib has no
      // constants for. These are Android FRAMEWORK ids, not BYD feature ids;
      // they're intrinsic to rewriting a binary AndroidManifest and have no
      // proto home to move to.
      'android/app/src/main/kotlin/com/i99dev/ilink/clusterpatch/ManifestPatcher.kt',
      // Nav-HUD 7.0UI CAN-FID writer — reflects the BYD instrument HAL
      // (`android.hardware.bydauto.instrument.BYDAutoInstrumentDevice` /
      // `.BYDAutoEventValue`) from a shell `app_process` to drive the Leopard 7
      // cluster. The HAL class name must appear in source to reflect it; this is
      // the sole nav-side reacher (mirrors BydAutoFeatureIdsCatalog's exemption).
      'android/app/src/main/kotlin/com/i99dev/ilink/nav/transport/canfid/InstrumentHalWriter.kt',
      // This test itself names the forbidden patterns.
      'test/core/car/forbidden_strings_test.dart',
    };

    // Scanned extensions — source trees only.
    const scanExtensions = <String>{'.dart', '.kt', '.java'};

    // Directories not worth scanning.
    const skipDirectories = <String>{
      'build',
      '.build', // ignored local generated protobuf/test artifacts, never source.
      '.dart_tool',
      '.gradle',
      '.idea',
      'ios',
      'macos',
      'linux',
      'windows',
      'web',
      'proto', // proto schema file declares field names, not constants.
      // Git worktrees are transient checkouts of other branches — their
      // leaks belong to those branches' allowlists, not master's.
      '_wt',
    };

    final patterns = <({String name, RegExp pattern})>[
      (
        name: 'hex feature id (8 hex digits, non-ARGB)',
        // 0x followed by exactly 8 hex digits — BYD feature ids are all
        // 32-bit. Skip `0xFF...` (Flutter ARGB Color literals, always
        // opaque with 0xFF alpha) so the gate targets real feature IDs.
        pattern: RegExp(r'0x(?!FF|ff)[0-9A-Fa-f]{8}\b'),
      ),
      (
        name: 'AIDL descriptor com.byd.ac.I*',
        pattern: RegExp(r'com\.byd\.ac\.I[A-Z]\w+'),
      ),
      (
        name: 'system service name byd_airconditioning',
        pattern: RegExp(r'\bbyd_airconditioning\b'),
      ),
      (
        name: 'reflection class BYDAutoManager',
        pattern: RegExp(r'\bBYDAutoManager\b'),
      ),
      (
        name: 'BYD system package android.hardware.bydauto',
        pattern: RegExp(r'\bandroid\.hardware\.bydauto\b'),
      ),
      // RENAME_BYD_DEVICE_ID_CONTRACT.md parity gates. Every pre-rename
      // spelling of the device id must live only inside the BYD adapter
      // subtree (which still produces the `byd:` prefix), the rename
      // contract / changelog, or this parity test itself.
      (
        name: 'pre-rename snake_case byd_device_id',
        pattern: RegExp(r'\bbyd_device_id\b'),
      ),
      (
        name: 'pre-rename camelCase bydDeviceId',
        pattern: RegExp(r'\bbydDeviceId\b'),
      ),
      (
        name: 'pre-rename PascalCase BydDeviceId',
        pattern: RegExp(r'\bBydDeviceId\w*'),
      ),
      (
        name: 'pre-rename SCREAMING_SNAKE BYD_DEVICE_ID',
        pattern: RegExp(r'\bBYD_DEVICE_ID\b'),
      ),
      (
        name: 'pre-rename kebab-case byd-device-id',
        pattern: RegExp(r'\bbyd-device-id\b'),
      ),
    ];

    test('every leak has a justified home', () {
      final leaks = <_Leak>[];
      _walk(root, skipDirectories, scanExtensions, (file) {
        final rel = _relative(root, file);
        if (allowlistedPaths.contains(rel)) return;
        final raw = file.readAsStringSync();
        // Strip comments so prose documentation referencing the system
        // doesn't trip the gate. Real leaks live in code, not doc.
        final scanned = _stripComments(raw);
        for (final p in patterns) {
          for (final match in p.pattern.allMatches(scanned)) {
            final line = _lineNumberForOffset(scanned, match.start);
            leaks.add(_Leak(rel, p.name, match.group(0)!, line));
          }
        }
      });
      expect(
        leaks,
        isEmpty,
        reason:
            'Reverse-engineered constants leaked outside the allowlist:\n'
            '${leaks.map((l) => '  ${l.path}:${l.line}  '
                '[${l.pattern}] ${l.match}').join('\n')}\n'
            'Either move the constant into one of the allowlisted files, or '
            'add the new file to forbidden_strings_test.dart with a comment '
            'describing why it can live there.',
      );
    });
  });
}

class _Leak {
  _Leak(this.path, this.pattern, this.match, this.line);
  final String path;
  final String pattern;
  final String match;
  final int line;
}

void _walk(
  Directory root,
  Set<String> skipDirs,
  Set<String> scanExtensions,
  void Function(File) visit,
) {
  for (final entity in root.listSync(followLinks: false)) {
    if (entity is Directory) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (skipDirs.contains(name)) continue;
      _walk(entity, skipDirs, scanExtensions, visit);
    } else if (entity is File) {
      final ext = _extension(entity.path);
      if (scanExtensions.contains(ext)) visit(entity);
    }
  }
}

String _extension(String path) {
  final i = path.lastIndexOf('.');
  return i < 0 ? '' : path.substring(i);
}

String _relative(Directory root, File file) {
  final rootPath = root.path.replaceAll('\\', '/');
  final filePath = file.path.replaceAll('\\', '/');
  if (filePath.startsWith('$rootPath/')) {
    return filePath.substring(rootPath.length + 1);
  }
  return filePath;
}

int _lineNumberForOffset(String content, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < content.length; i++) {
    if (content.codeUnitAt(i) == 0x0A) line++;
  }
  return line;
}

/// Replace comment bodies with whitespace (not removal) so offsets — and
/// therefore line numbers reported in leak messages — stay aligned with
/// the original source. Handles `//` line comments and `/* */` block
/// comments. Doesn't try to respect strings; a forbidden literal inside a
/// string is still a leak, which is the behaviour we want.
String _stripComments(String s) {
  final buf = StringBuffer();
  var i = 0;
  while (i < s.length) {
    if (i + 1 < s.length && s[i] == '/' && s[i + 1] == '/') {
      while (i < s.length && s[i] != '\n') {
        buf.write(' ');
        i++;
      }
    } else if (i + 1 < s.length && s[i] == '/' && s[i + 1] == '*') {
      buf.write('  ');
      i += 2;
      while (i + 1 < s.length && !(s[i] == '*' && s[i + 1] == '/')) {
        buf.write(s[i] == '\n' ? '\n' : ' ');
        i++;
      }
      if (i + 1 < s.length) {
        buf.write('  ');
        i += 2;
      }
    } else {
      buf.write(s[i]);
      i++;
    }
  }
  return buf.toString();
}

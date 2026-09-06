// Hex-literal audit. Fails CI when a 0x[0-9a-fA-F]{4,} literal lives in
// a place that should be free of feature IDs. The intent: feature IDs
// (door lock, AC fan, etc.) live in the bundled dispatch table
// at `android/app/src/main/assets/offline/car_table.textproto`; their presence anywhere
// else means the centralisation regressed.
//
// What's allowed:
//   * Theme / color literals (Color(0xFFxxxxxx), MaterialColor, etc.).
//   * The proto schema directory (declares example values).
//   * AutoFeatureService — wait, this used to host hardcoded telemetry
//     reads. After P1.5 it reads from CarTableSource.statusKeys() and
//     should NOT contain hex literals anymore. Listed under the BLOCK
//     set, not the allowlist.
//   * Protocol constants — ADB version (`A_VERSION = 0x01000000`),
//     bitmasks (`0xFFFFFFFFL`), magic numbers — recognised by name
//     pattern, not path.
//
// Run: `dart run tool/audit_hex.dart`
// Exit 0 if clean, 1 with a list of offenders otherwise.

import 'dart:io';

void main(List<String> args) async {
  final repoRoot = Directory.current;

  // Source roots to scan.
  final scanRoots = ['lib', 'android/app/src/main/kotlin'];

  // Files allowed to carry hex feature IDs. Each entry costs an
  // explicit justification.
  const allowedFiles = <String>{
    // Color theme — Color(0xFFxxxxxx) literals are not feature IDs.
    // Filtered out by the regex below, but listed here as a defence-
    // in-depth allow.
    'lib/kernel/ui/theme/app_theme.dart',
    'lib/kernel/ui/theme/colors.dart',
    // Display-calibration tour: a 5-element list of per-display marker
    // ARGB constants (`_kProbeColors`). Stored as raw ints (passed
    // across the bridge as `colorArgb`), never wrapped in `Color(...)`,
    // so the benignContext color patterns don't catch them.
    'lib/features/home/presentation/widgets/calibration/display_tour_overlay.dart',
    // Kotlin package-platform plugin — uses 0xFFAA33FF.toInt() as a
    // raw ARGB fallback color (notification accent). Not a feature ID;
    // .toInt() is the standard Kotlin Long→Int widening for color packs.
    'android/app/src/main/kotlin/com/i99dev/ilink/pkg/PackagePlatformPlugin.kt',
    // Launcher bootstrap — uses 0x4F4D45 ("OME") as the role-request
    // intent code. ASCII-packed request code, not a feature ID;
    // documented inline next to the literal.
    'android/app/src/main/kotlin/com/i99dev/ilink/launcher/LauncherBootstrapPlugin.kt',
    // On-device Arabic voice grammar — the 0x06xx literals are ARABIC
    // UNICODE CODEPOINTS (U+0623 أ, U+0627 ا, U+0649 ى, U+0640 tatweel,
    // …) used to fold dialectal letter variants during Moonshine
    // normalization. They are character codepoints, not feature IDs.
    'lib/features/voice/ondevice/voice_grammar.dart',
    // Nav-HUD text sanitizer — the 0x4E00/0x3400/0xF900 literals are CJK
    // UNICODE RANGES (`c.code in 0x4E00..0x9FFF`) used to decide whether a
    // road name needs transliteration. Codepoints, not feature IDs.
    'android/app/src/main/kotlin/com/i99dev/ilink/nav/logic/HudTextSanitizer.kt',
    // Nav-HUD maneuver icons — PAINT_COLOR = 0xFF00E5FF.toInt() is the ARGB
    // arrow tint (byte-faithful to OpenBYD). A color, not a feature ID.
    'android/app/src/main/kotlin/com/i99dev/ilink/nav/transport/ManeuverIconBitmaps.kt',
    // Cluster-app patcher manifest editor — pins AOSP `android:*` attribute
    // resource ids (0x010104f6 = resizeableActivity) that ARSCLib lacks
    // constants for. Android FRAMEWORK ids, not BYD feature ids.
    'android/app/src/main/kotlin/com/i99dev/ilink/clusterpatch/ManifestPatcher.kt',
  };

  // Patterns whose hex literals are protocol constants, not feature
  // IDs. Recognised by the surrounding context line.
  final benignContext = [
    RegExp(r'Color\s*\(\s*0x'), // Flutter Color literals
    RegExp(r'MaterialColor\s*\(\s*0x'),
    RegExp(r'Border|Shadow|Box.*Color'),
    // ADB protocol opcodes — every line is `const val CMD_xxx = 0x...`
    // and the surrounding identifier names are protocol-specific.
    RegExp(r'\bA_VERSION\b|\bA_CNXN\b|\bA_AUTH\b'),
    RegExp(r'\bCMD_(CNXN|AUTH|OPEN|OKAY|WRTE|CLSE|SYNC)\b'),
    // All-F bitmasks — never confuse a feature ID with these.
    RegExp(r'\b0x[fF]{4,8}L?\b'),
    RegExp(r'\b0xFF\b'),
    // Bitmask context — `& 0xXXX` / `| 0xXXX` / `>> 0xXXX` patterns
    // are arithmetic, not feature-ID literals.
    RegExp(r'[&|^]\s*0x[0-9a-fA-F]+'),
    RegExp(r'<<\s*0x|>>\s*0x'),
    // Unicode codepoint comparisons — `c == 0xXXXX`, `code >= 0xXXXX`
    // commonly appear in i18n / parser code. Codepoints are usually
    // <= 0xFFFF; loose match here, tighter check via name pattern below.
    RegExp(r'\b(code|c|ch|rune|unit)\b\s*[=<>!]+\s*0x[0-9a-fA-F]+'),
    // 24-bit color mask used for ambient lamp packing in atmos.
    RegExp(r'0xFFFFFF'),
    // `colorArgb` on the line — bridge handlers receive ARGB ints
    // for tourMarker / overlay tinting, never feature IDs.
    RegExp(r'\bcolorArgb\b'),
    RegExp(r'//.*0x[0-9a-fA-F]+'), // comment-only hex
    RegExp(r"'\s*//\s*0x"),
  ];

  // The match: 4+ hex digits prefixed with 0x, anywhere in source.
  final hexRe = RegExp(r'\b0x[0-9a-fA-F]{4,}\b');

  final offenders = <String>[];
  for (final root in scanRoots) {
    final dir = Directory('${repoRoot.path}/$root');
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File) continue;
      final path = entity.absolute.path
          .substring(repoRoot.absolute.path.length + 1)
          .replaceAll(r'\', '/');
      if (allowedFiles.contains(path)) continue;
      if (!path.endsWith('.dart') &&
          !path.endsWith('.kt') &&
          !path.endsWith('.java')) {
        continue;
      }
      // Skip generated proto outputs.
      if (path.contains('/build/') || path.contains('/.dart_tool/')) {
        continue;
      }

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (!hexRe.hasMatch(line)) continue;
        // Skip if the line is a benign protocol/color context.
        if (benignContext.any((p) => p.hasMatch(line))) continue;
        // Skip whole-line comments.
        final trimmed = line.trimLeft();
        if (trimmed.startsWith('//') ||
            trimmed.startsWith('/*') ||
            trimmed.startsWith('*') ||
            trimmed.startsWith('#')) {
          continue;
        }
        offenders.add('$path:${i + 1}: ${line.trim()}');
      }
    }
  }

  if (offenders.isEmpty) {
    stdout.writeln('audit_hex: clean — no stray feature-ID hex literals.');
    exit(0);
  }

  stderr.writeln(
    'audit_hex: ${offenders.length} offending line(s) — feature IDs must '
    'live in android/app/src/main/assets/offline/car_table.textproto, not in source code:',
  );
  for (final o in offenders) {
    stderr.writeln('  $o');
  }
  stderr.writeln('');
  stderr.writeln(
    'If a hit is a non-feature-ID hex literal (protocol constant, '
    'bitmask, color), add the file to allowedFiles in tool/audit_hex.dart '
    'or extend benignContext.',
  );
  exit(1);
}

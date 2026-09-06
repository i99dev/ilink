import '../domain/app_meta.dart';

/// Pure parsers for `pm` / `dumpsys package` / `dumpsys deviceidle`
/// output. Golden-file tested.
///
/// Inputs are raw command stdouts; outputs are typed [AppMeta]
/// fragments that the controller composes into a final value.
class PackageMetaReader {
  const PackageMetaReader._();

  /// Parse `dumpsys package <pkg>`. Looks for the canonical anchors
  /// every Android version emits.
  ///
  /// Anchors:
  ///   * `flags=[ ... SYSTEM ... ]` → isSystem
  ///   * `enabled=true|false`        → enabled
  ///   * `versionName=...`           → versionName
  ///   * `installerPackageName=...`  → installerPackage
  ///   * `codeSize=N`/`dataSize=N`   → sizeBytes (best-effort sum)
  static AppMeta parsePackageDump(String dump, {required String packageName}) {
    final flags = RegExp(r'flags=\[([^\]]*)\]').firstMatch(dump);
    final isSystem = flags != null && flags.group(1)!.contains('SYSTEM');
    final enabledMatch = RegExp(r'\benabled=(\w+)\b').firstMatch(dump);
    final enabled = enabledMatch == null
        ? true
        : enabledMatch.group(1)!.toLowerCase() != 'false' &&
              enabledMatch.group(1)! != '2' && // DISABLED_USER
              enabledMatch.group(1)! != '3'; // DISABLED_UNTIL_USED
    final version = RegExp(r'versionName=([^\s]+)').firstMatch(dump)?.group(1);
    final installer = RegExp(
      r'installerPackageName=([^\s]+)',
    ).firstMatch(dump)?.group(1);
    final code = _intAfter(dump, 'codeSize=') ?? 0;
    final data = _intAfter(dump, 'dataSize=') ?? 0;
    final cache = _intAfter(dump, 'cacheSize=') ?? 0;
    final size = code + data + cache;

    return AppMeta(
      targetKey: packageName,
      enabled: enabled,
      isSystem: isSystem,
      // System apps can be disabled but not uninstalled by user.
      canUninstall: !isSystem,
      // Whitelist state is sourced from `dumpsys deviceidle whitelist`,
      // not here. Default to false; controller composes them together.
      inDozeWhitelist: false,
      versionName: version == 'null' ? null : version,
      installerPackage: installer == 'null' ? null : installer,
      sizeBytes: size > 0 ? size : null,
      runningTaskId: null, // populated by parseRunningTasks
    );
  }

  /// Parse `dumpsys deviceidle whitelist`. Returns the set of package
  /// names currently whitelisted for doze.
  ///
  /// Output format (AOSP 8+):
  ///   ```
  ///   system-excidle:
  ///     com.android.providers.downloads,1000
  ///     com.android.cellbroadcastreceiver,...
  ///   user:
  ///     com.example.myapp,...
  ///   ```
  /// We accept both leading-whitespace lines and bare entries.
  static Set<String> parseDozeWhitelist(String dump) {
    final pkgs = <String>{};
    final pkgPattern = RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+');
    for (final raw in dump.split('\n')) {
      final line = raw.trim();
      // Strip trailing `,uid` if present.
      final pkg = line.split(',').first.trim();
      if (pkgPattern.hasMatch(pkg)) pkgs.add(pkg);
    }
    return pkgs;
  }

  /// Parse `dumpsys activity recents` or `dumpsys activity activities`
  /// (both work) to find running task ids per package. We're only
  /// interested in the most-recently-active task per package — the
  /// Move action moves "the running task" without distinguishing.
  ///
  /// Output anchor:
  ///   `Recent #N: ... TaskRecord{...} I=<intent>... A=com.example...`
  static Map<String, int> parseRunningTasks(String dump) {
    final out = <String, int>{};
    // Two passes: first try the recent-task block, then activity-stack.
    final recentPattern = RegExp(
      r'Recent\s+#\d+:\s.*?A=([A-Za-z][A-Za-z0-9_.]+).*?(?:taskId=|\* Task\{[a-f0-9]+\s+#)(\d+)',
      multiLine: true,
      dotAll: true,
    );
    for (final m in recentPattern.allMatches(dump)) {
      final pkg = m.group(1);
      final tid = int.tryParse(m.group(2) ?? '');
      if (pkg != null && tid != null) {
        out.putIfAbsent(pkg, () => tid);
      }
    }
    return out;
  }

  /// Parse `pm list packages -3` (third-party only) and `pm list packages -d`
  /// (disabled). Returns the union as `(pkg, enabled)` rows.
  static List<({String packageName, bool enabled})> parsePackageList({
    required String thirdPartyOutput,
    required String disabledOutput,
  }) {
    final disabled = <String>{};
    for (final line in disabledOutput.split('\n')) {
      final t = line.trim();
      if (t.startsWith('package:')) disabled.add(t.substring(8).trim());
    }
    final out = <({String packageName, bool enabled})>[];
    for (final line in thirdPartyOutput.split('\n')) {
      final t = line.trim();
      if (!t.startsWith('package:')) continue;
      final pkg = t.substring(8).trim();
      if (pkg.isEmpty) continue;
      out.add((packageName: pkg, enabled: !disabled.contains(pkg)));
    }
    return out;
  }

  static int? _intAfter(String haystack, String anchor) {
    final m = RegExp('$anchor(\\d+)').firstMatch(haystack);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }
}

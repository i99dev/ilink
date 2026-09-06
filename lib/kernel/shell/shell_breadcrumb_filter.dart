import 'dart:convert';
import 'package:crypto/crypto.dart';

/// PII-scrub for shell command breadcrumbs.
///
/// Package names CAN be PII — a user's installed app list is sensitive
/// (private apps, dating apps, banking apps, journalist tools). We
/// SHA-256 every dotted token before logs leave the device.
///
/// Argv tokens that DON'T need scrubbing are preserved verbatim so
/// support engineers can still triage by command shape. Specifically:
///
///   * Bare command names (`pm`, `am`, `dumpsys`, `svc`, `settings`,
///     `cmd`, `getprop`) — public Android surface.
///   * Subcommands and flags (`enable`, `disable-user`, `--user`, `0`,
///     `-3`, `-f`, `+`, `-`) — same.
///   * Numeric ids (display ids, task ids).
///   * Known shell tokens (`|`, `&&`, `;`, `>`, `2>&1`, `head`, `grep`).
///
/// What gets hashed: anything that looks like an Android package name
/// (`com.foo.bar`) or a userland identifier (any token containing a
/// dot AND only `[a-zA-Z0-9._]`).
class ShellBreadcrumbFilter {
  const ShellBreadcrumbFilter();

  // Tokens that look like Android package names get hashed. Other
  // dotted tokens (system property keys like `persist.sys.cloud.last_vin`)
  // are also hashed — they can encode car-specific identifiers.
  static final RegExp _packageLike = RegExp(
    r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$',
  );

  /// Map argv to a breadcrumb-safe joined string. Stable per package
  /// (same input → same hash) so support can correlate across logs
  /// without the user's installed-app list ever leaving the device.
  String scrub(List<String> argv) {
    return argv.map(_scrubToken).join(' ');
  }

  String _scrubToken(String tok) {
    if (!_packageLike.hasMatch(tok)) return tok;
    final hash = sha256.convert(utf8.encode(tok)).toString();
    // 8 hex chars (32 bits) is plenty to disambiguate within a single
    // user's logs without leaking entropy on which package it is.
    return 'pkg:${hash.substring(0, 8)}';
  }
}

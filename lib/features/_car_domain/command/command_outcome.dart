import 'dart:async';

import 'package:flutter/services.dart';

/// Classifies a bridge failure by root cause. Keeping this as an enum
/// (not a sealed class) because every branch carries the same payload —
/// code + message live on [CommandOutcome] already; the kind is just
/// the tag the UI / logging / analytics use to decide tone and retry
/// policy.
///
/// - [timeout]       — `CarBridge._guard` tripped its timeout; the
///                     command may or may not have landed on Kotlin.
/// - [daemonOffline] — daemon isn't ready / ADB isn't connected; the
///                     action can't be attempted at all.
/// - [platform]      — `PlatformException` from the MethodChannel (the
///                     Kotlin side threw).
/// - [rejected]      — the daemon received the command but refused it
///                     (vehicle-side safety gate, unknown action id).
/// - [other]         — generic Dart-side exception (JSON shape drift,
///                     cancelled future, etc.).
enum BridgeErrorKind { timeout, daemonOffline, platform, rejected, other }

/// Uniform result for any car command. Replaces the ad-hoc
/// `Map<String, dynamic>` returns we were passing around. UI asks for
/// `outcome.ok` + `outcome.message`, backends get `outcome.toJson()`.
class CommandOutcome {
  const CommandOutcome._({
    required this.ok,
    this.code,
    this.message,
    this.data,
    this.errorKind,
  });

  factory CommandOutcome.success([Map<String, dynamic>? data, int? code]) =>
      CommandOutcome._(ok: true, data: data, code: code);

  factory CommandOutcome.failure(
    String message, {
    int? code,
    BridgeErrorKind errorKind = BridgeErrorKind.other,
  }) => CommandOutcome._(
    ok: false,
    message: message,
    code: code,
    errorKind: errorKind,
  );

  /// Parse the raw map that comes back from the Kotlin MethodChannel.
  ///
  /// The Dart bridge (`CarBridge._guard`) stamps timeouts with a
  /// sentinel `'code': 'CAR_BRIDGE_TIMEOUT'` — that's how this factory
  /// tells a platform timeout apart from a daemon-level rejection.
  factory CommandOutcome.fromBridge(dynamic raw) {
    if (raw is int) {
      return raw == 0
          ? CommandOutcome.success(null, raw)
          : CommandOutcome.failure(
              'native code=$raw',
              code: raw,
              errorKind: BridgeErrorKind.rejected,
            );
    }
    if (raw is Map) {
      final map = raw.cast<String, dynamic>();
      if (map.containsKey('error')) {
        final c = map['code'];
        final codeInt = c is int ? c : null;
        final kind = _kindFromMap(map);
        return CommandOutcome.failure(
          map['error']?.toString() ?? 'error',
          code: codeInt,
          errorKind: kind,
        );
      }
      final codeVal = map['code'];
      final code = codeVal is int ? codeVal : null;
      final ok = map['ok'] == true || code == 0;
      return ok
          ? CommandOutcome.success(map, code)
          : CommandOutcome.failure(
              'native code=$code',
              code: code,
              errorKind: BridgeErrorKind.rejected,
            );
    }
    return CommandOutcome.failure(
      'unexpected bridge result: $raw',
      errorKind: BridgeErrorKind.other,
    );
  }

  /// Typed factory for exception-path failures. Callers (controllers,
  /// voice handler) use this in `catch` blocks so timeout / platform /
  /// other get distinguished downstream without string-matching.
  factory CommandOutcome.fromException(Object e) {
    if (e is TimeoutException) {
      return CommandOutcome.failure(
        'timeout',
        errorKind: BridgeErrorKind.timeout,
      );
    }
    if (e is PlatformException) {
      return CommandOutcome.failure(
        e.message ?? e.code,
        errorKind: BridgeErrorKind.platform,
      );
    }
    return CommandOutcome.failure(
      e.toString(),
      errorKind: BridgeErrorKind.other,
    );
  }

  static BridgeErrorKind _kindFromMap(Map<String, dynamic> map) {
    final codeStr = map['code']?.toString();
    if (codeStr == 'CAR_BRIDGE_TIMEOUT') return BridgeErrorKind.timeout;
    if (codeStr == 'DAEMON_OFFLINE' || map['daemon'] == false) {
      return BridgeErrorKind.daemonOffline;
    }
    return BridgeErrorKind.rejected;
  }

  final bool ok;
  final int? code;
  final String? message;
  final Map<String, dynamic>? data;

  /// Null on success; one of the [BridgeErrorKind] values on failure so
  /// callers can branch on root cause (retry on timeout, surface a
  /// different banner on daemon offline, etc.).
  final BridgeErrorKind? errorKind;

  String describe(String action) =>
      ok ? '$action: ok' : '$action: ${message ?? 'failed'}';

  Map<String, dynamic> toJson() => {
    if (ok) 'ok': true else 'error': message ?? 'failed',
    if (code != null) 'code': code,
    if (errorKind != null) 'error_kind': errorKind!.name,
    ...?data,
  };
}

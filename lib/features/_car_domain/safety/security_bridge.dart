import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Dart side of the security subsystem. Mirrors the Kotlin [SecurityChannel]
/// and is the single place in Dart that hashes inputs + forwards events.
/// Keeping it small so the router's hot path is one `await` per dispatch.
///
/// Every string passed to [logDispatch] / [logBurst] must already be opaque
/// (prefixed with `sha256:` or a controlled enum name). Plaintext command
/// ids or args MUST NOT cross this boundary — the hashing happens here so
/// callers can't accidentally forget.
///
/// Deliberately depends on nothing but `flutter/services.dart` — every
/// channel call is wrapped in a try/catch and degrades silently on
/// `MissingPluginException` / `PlatformException`. That means tests and
/// mock runs don't need to wire or mock anything: the channel is simply
/// absent, every call no-ops, and `integrityHealthy()` fails open.
class SecurityBridge {
  const SecurityBridge();

  static const _channel = MethodChannel('ilink/security');

  /// Hash-and-emit a dispatch event. Fire-and-forget; errors are swallowed
  /// because the logger must never block the dispatch path.
  Future<void> logDispatch({
    required String commandId,
    required Map<String, dynamic> args,
    required String outcome,
    required Duration latency,

    /// Free-form caller kind label (e.g. `host_ui`, `voice`,
    /// `mini_app_standard`). Optional during F3 migration; once the
    /// gateway facade is the only entry point this becomes required.
    String? caller,
  }) async {
    try {
      await _channel.invokeMethod<bool>('logDispatch', {
        'cmd': _sha256(commandId),
        'args': _sha256(_canonicalise(args)),
        'outcome': outcome,
        'latency_ms': latency.inMilliseconds,
        // ignore: use_null_aware_elements
        if (caller != null) 'caller': caller,
      });
    } catch (_) {
      // Logger unavailable (mock, test, channel not registered, etc.).
      // Silent by design — observability can't break primary function.
    }
  }

  Future<void> logBurst({
    required String rateClass,
    required bool started,
  }) async {
    try {
      await _channel.invokeMethod<bool>('logBurst', {
        'class': rateClass,
        'started': started,
      });
    } catch (_) {
      // ignore
    }
  }

  /// Queried once per dispatch by the router. On failure we fail *open* —
  /// an unreachable logger must not brick the car. True tamper is the
  /// signal that matters; transient channel errors are not.
  Future<bool> integrityHealthy() async {
    try {
      return await _channel.invokeMethod<bool>('integrityHealthy') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// The ETag co-located with the on-disk v2 blob for [kind]
  /// (`car_table` / `mini_app_table`) — the plaintext sha256 from the
  /// last fetch, or null when no blob is stored (Kotlin returns null if
  /// the blob file is absent, so a missing/cleared table forces a full
  /// re-fetch rather than a stale `304` loop). Sent as `If-None-Match`.
  Future<String?> v2TableEtag(String kind) async {
    try {
      return await _channel.invokeMethod<String>('v2TableEtag', {'kind': kind});
    } catch (_) {
      return null;
    }
  }

  /// One-shot v2 load diagnostic — see Kotlin `SecurityChannel.v2Diag`.
  /// Reports secret presence / blob sizes / live source version / the
  /// actual car_table decrypt outcome, for debugging why the per-install
  /// v2 table isn't loading on a car that has the blob on disk. No secret
  /// material crosses the channel. Null on channel absence (mock/test).
  Future<String?> v2Diag() async {
    try {
      return await _channel.invokeMethod<String>('v2Diag');
    } catch (_) {
      return null;
    }
  }

  /// Canonical JSON so `args` hash is stable across map iteration orders.
  /// Keys are sorted at each object level; values are stringified once.
  static String _canonicalise(Map<String, dynamic> args) {
    final sorted = _sortRecursively(args);
    return jsonEncode(sorted);
  }

  static Object? _sortRecursively(Object? node) {
    if (node is Map) {
      final keys = node.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: _sortRecursively(node[k])};
    }
    if (node is Iterable) {
      return [for (final v in node) _sortRecursively(v)];
    }
    return node;
  }

  static String _sha256(String input) {
    final digest = sha256.convert(utf8.encode(input));
    return digest.toString(); // hex
  }
}

final securityBridgeProvider = Provider<SecurityBridge>(
  (_) => const SecurityBridge(),
);

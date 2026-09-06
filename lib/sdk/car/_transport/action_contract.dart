import 'package:flutter/foundation.dart';

import '../../_internal/logger.dart';
import 'car_bridge.dart';

/// Debug-only handshake that verifies an expected wire-id set matches
/// what the Kotlin `UnitDispatcher` reports via `knownActions()`. The
/// caller (typically the app's `BydClient.verifyActionContract`) passes
/// its `ActionIds.all` so the SDK doesn't need to import app-side
/// constants — keeps the bridge boundary clean.
///
/// No-op in release and under mock mode (Kotlin returns an empty list).
Future<void> verifyActionContract(
  CarBridge bridge, {
  required Set<String> expected,
}) async {
  if (!kDebugMode) return;
  const log = Logger('ActionContract');
  try {
    final known = (await bridge.knownActions()).toSet();
    if (known.isEmpty) return; // mock mode or daemon offline — skip.
    final dartOnly = expected.difference(known);
    final kotlinOnly = known.difference(expected);
    if (dartOnly.isEmpty && kotlinOnly.isEmpty) {
      log.i('action id contract ok (${known.length} ids)');
      return;
    }
    if (dartOnly.isNotEmpty) {
      log.w('action ids declared in Dart but missing on Kotlin: $dartOnly');
    }
    if (kotlinOnly.isNotEmpty) {
      log.w(
        'action ids on Kotlin but missing from Dart expected set: $kotlinOnly',
      );
    }
  } catch (e) {
    log.w('action contract verify failed: $e');
  }
}

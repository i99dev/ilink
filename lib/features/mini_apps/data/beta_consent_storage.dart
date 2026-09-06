import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists beta-consent acknowledgements keyed on `(userId, appId, version)`.
///
/// The triple ensures the consent sheet re-appears when:
///  - A different user signs in (different userId).
///  - The developer pushes a new beta build (version bumps).
///
/// ## Storage format
///
/// Persisted as a JSON array of `"$userId/$appId/$version"` strings under
/// `'mini_apps.beta_consent'`. The array shape is the canonical format
/// going forward; for backward compatibility the reader also accepts the
/// previous `Map<String, bool>` shape (where the value was always `true`)
/// and migrates it forward on the first write.
///
/// ### Migration is one-way
///
/// Once a process running this code writes back, the blob is in the new
/// list format. A user who downgrades to an older client that only knows
/// the map shape will see an empty consent set on read (and re-prompt
/// once per beta). Acceptable for an opt-in beta-tester audience where
/// downgrades are rare.
///
/// ## In-memory cache
///
/// The decoded set is held in [_cached] for the lifetime of the
/// instance. Reads after the first `_load()` skip both SharedPreferences
/// and `jsonDecode`. Writes update both [_cached] and the underlying
/// pref so subsequent `hasConsented` calls see the change immediately
/// (read-through, write-back). [clear] resets the cache so a fresh
/// `_load` runs on the next access.
///
/// All mutations of consent state must go through this class. Direct
/// SharedPreferences writes elsewhere would bypass the cache and cause
/// stale reads until the next process restart.
class BetaConsentStorage {
  BetaConsentStorage(this._prefsFactory);

  final Future<SharedPreferences> Function() _prefsFactory;

  static const _key = 'mini_apps.beta_consent';

  /// Lazy in-memory mirror of the on-disk set. `null` = not loaded
  /// yet; the first `_ensureLoaded()` populates it.
  Set<String>? _cached;

  /// Returns true when the user has already acknowledged the beta
  /// consent for this exact `(userId, appId, version)` triple.
  Future<bool> hasConsented({
    required String userId,
    required String appId,
    required String version,
  }) async {
    final set = await _ensureLoaded();
    return set.contains(_tripleKey(userId, appId, version));
  }

  /// Records that the user consented for this `(userId, appId, version)`.
  /// Idempotent — re-recording an existing triple is a no-op.
  Future<void> recordConsent({
    required String userId,
    required String appId,
    required String version,
  }) async {
    final set = await _ensureLoaded();
    final key = _tripleKey(userId, appId, version);
    if (!set.add(key)) return; // already recorded
    await _save(set);
  }

  /// Clears all stored consents. Used by sign-out / wipe flows. Drops
  /// the in-memory cache so the next read goes back to disk.
  Future<void> clear() async {
    _cached = null;
    await (await _prefsFactory()).remove(_key);
  }

  static String _tripleKey(String userId, String appId, String version) =>
      '$userId/$appId/$version';

  /// Returns the cached set, populating it from disk on first call.
  Future<Set<String>> _ensureLoaded() async {
    final cached = _cached;
    if (cached != null) return cached;
    final fresh = await _loadFromDisk();
    _cached = fresh;
    return fresh;
  }

  /// Decodes the on-disk blob, accepting both the new list format and
  /// the legacy `Map<String, bool>` format. Returns an empty set on
  /// missing or corrupt storage — better to re-show the sheet than
  /// brick the launch path.
  Future<Set<String>> _loadFromDisk() async {
    try {
      final raw = (await _prefsFactory()).getString(_key);
      if (raw == null || raw.isEmpty) return <String>{};
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return {
          for (final entry in decoded)
            if (entry is String) entry,
        };
      }
      if (decoded is Map<String, dynamic>) {
        // Legacy format: map keys are the triples; values are always true.
        return {for (final entry in decoded.keys) entry};
      }
    } catch (_) {
      // Corrupt blob — treat as empty.
    }
    return <String>{};
  }

  /// Persists [set] as a JSON list. Failures are non-fatal (worst case
  /// the user re-consents on next launch).
  Future<void> _save(Set<String> set) async {
    try {
      await (await _prefsFactory()).setString(_key, jsonEncode(set.toList()));
    } catch (_) {
      // Write failure is non-fatal.
    }
  }
}

final betaConsentStorageProvider = Provider<BetaConsentStorage>((_) {
  return BetaConsentStorage(SharedPreferences.getInstance);
});

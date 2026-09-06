import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the user's home-strip favourite mini-app ids.
///
/// Storage shape: a JSON list of mini-app ids ordered as the user
/// arranged them. SharedPreferences key: `mini_apps.favorites`.
///
/// Defaults: when nothing has ever been written, the strip seeds with
/// the first-party reference apps so a fresh install shows something
/// the moment it boots. The default list applies only on the very
/// first read; once the user adds or removes anything we trust the
/// stored list verbatim — including an empty one. Persisting an empty
/// list is the difference between "user removed everything on
/// purpose" and "untouched fresh install" (the latter still resolves
/// to defaults until first write).
///
/// Mirrors the read-through / write-back / in-memory-cache pattern of
/// [BetaConsentStorage] — same lifetime semantics, same failure modes
/// (corrupt blob → falls back to defaults; write failure → non-fatal).
class FavoriteMiniAppsStorage {
  FavoriteMiniAppsStorage(this._prefsFactory);

  final Future<SharedPreferences> Function() _prefsFactory;

  static const _key = 'mini_apps.favorites';

  /// Reference apps shipped with every fresh install. Resolved lazily
  /// against the catalog at render time, so an id that doesn't (yet)
  /// resolve to an installed app is silently skipped instead of
  /// rendering a broken tile.
  static const List<String> defaults = ['pkg-launcher', 'dash-wallpaper'];

  /// Lazy in-memory mirror. ``null`` = not loaded yet; first
  /// [_ensureLoaded] populates it.
  List<String>? _cached;

  /// Read the current favourite ids. Order matches user arrangement.
  Future<List<String>> load() async {
    final cached = _cached;
    if (cached != null) return List.unmodifiable(cached);
    final fresh = await _loadFromDisk();
    _cached = fresh;
    return List.unmodifiable(fresh);
  }

  /// Replace the stored list. Ids are stored verbatim; callers are
  /// expected to dedupe and validate (the controller does both).
  Future<void> save(List<String> ids) async {
    _cached = List.of(ids);
    try {
      await (await _prefsFactory()).setString(_key, jsonEncode(ids));
    } catch (_) {
      // Write failure is non-fatal — the in-memory cache still
      // reflects the user's intent for the rest of this session.
    }
  }

  /// Drop both the cache and the on-disk blob so the next [load]
  /// re-seeds with [defaults]. Used by sign-out / wipe flows.
  Future<void> clear() async {
    _cached = null;
    try {
      await (await _prefsFactory()).remove(_key);
    } catch (_) {
      // Best-effort.
    }
  }

  Future<List<String>> _loadFromDisk() async {
    try {
      final raw = (await _prefsFactory()).getString(_key);
      if (raw == null) {
        // Nothing persisted yet — seed with defaults. Once the user
        // adds or removes anything (even down to an empty list) the
        // saved blob exists and we'll trust its contents on next
        // load instead of re-seeding.
        return List.of(defaults);
      }
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return [
          for (final entry in decoded)
            if (entry is String && entry.isNotEmpty) entry,
        ];
      }
    } catch (_) {
      // Corrupt blob — better to seed defaults than render an empty
      // strip on a fresh-looking install.
    }
    return List.of(defaults);
  }
}

final favoriteMiniAppsStorageProvider = Provider<FavoriteMiniAppsStorage>((_) {
  return FavoriteMiniAppsStorage(SharedPreferences.getInstance);
});

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One installed mini-app record. Keeps `installedAt` plus an optional
/// `certHash` so the privileged-install path can stamp the verified
/// developer-cert hash for later dispatch use without a second store.
class InstalledMiniAppRecord {
  const InstalledMiniAppRecord({
    required this.installedAt,
    this.certHash,
    this.bundleSha256,
  });

  final DateTime installedAt;

  /// SHA-256 hex of the cert this app was installed under. Null for
  /// non-privileged apps; populated by the privileged install
  /// pipeline after cert verification succeeds.
  final String? certHash;

  /// SHA-256 hex of the bundle bytes that were extracted to disk.
  /// Drives the auto-update check at launch: when the catalog SHA
  /// differs from this, the developer has published a new build and
  /// the launch path prompts (beta) or silently re-installs (production).
  /// Null on records written before SHA tracking shipped — those are
  /// treated as "unknown" and skip the auto-update prompt until the
  /// next manual reinstall stamps a fresh SHA.
  final String? bundleSha256;
}

/// On-device record of which mini-apps the user has pinned to "My Apps",
/// and when. A single JSON-encoded list under [_key] — each entry is
/// `{id, installed_at, cert_hash?}`.
///
/// The repository keeps the *remote* catalog shape honest; this storage
/// is where the purely-local decision ("I want this app on my home
/// screen") lives. Keeping them separate means a catalog that loses a
/// row doesn't corrupt what the user has installed — the catalog
/// controller simply skips orphaned install ids.
///
/// Mirrors [CompatReportStorage]'s factory-injection shape so tests can
/// hand in an in-memory SharedPreferences without globally mocking it.
class MiniAppInstallStorage {
  MiniAppInstallStorage(this._prefsFactory);

  final Future<SharedPreferences> Function() _prefsFactory;

  Future<SharedPreferences> get _prefs => _prefsFactory();

  static const _key = 'mini_apps.installed';

  /// Returns `{id → InstalledMiniAppRecord}`. Invalid / legacy blobs
  /// return an empty map rather than blow up — a corrupted pref
  /// should never lock the Store screen into an error state.
  ///
  /// Forward-compatible with the v1 shape (`{id, installed_at}`); old
  /// rows missing `cert_hash` decode with `certHash: null`.
  Future<Map<String, InstalledMiniAppRecord>> load() async {
    final raw = (await _prefs).getString(_key);
    if (raw == null || raw.isEmpty) return <String, InstalledMiniAppRecord>{};
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      final out = <String, InstalledMiniAppRecord>{};
      for (final m in list) {
        final id = m['id'] as String?;
        final ts = m['installed_at'] as String?;
        if (id == null || id.isEmpty) continue;
        final parsed = ts == null ? null : DateTime.tryParse(ts);
        out[id] = InstalledMiniAppRecord(
          installedAt: parsed ?? DateTime.now(),
          certHash: m['cert_hash'] as String?,
          bundleSha256: m['bundle_sha256'] as String?,
        );
      }
      return out;
    } catch (_) {
      return <String, InstalledMiniAppRecord>{};
    }
  }

  /// Convenience for callers that only need the install timestamps
  /// (the controller's catalog-merge path). Drops the cert-hash
  /// dimension — anything that needs it should call [load] directly.
  Future<Map<String, DateTime>> loadTimestamps() async {
    final records = await load();
    return {for (final e in records.entries) e.key: e.value.installedAt};
  }

  Future<void> _save(Map<String, InstalledMiniAppRecord> entries) async {
    final encoded = jsonEncode([
      for (final e in entries.entries)
        {
          'id': e.key,
          'installed_at': e.value.installedAt.toUtc().toIso8601String(),
          // Omit keys that are null — keeps the on-disk shape stable
          // for legacy records and avoids unnecessary `null` round-trips.
          if (e.value.certHash != null) 'cert_hash': e.value.certHash,
          if (e.value.bundleSha256 != null)
            'bundle_sha256': e.value.bundleSha256,
        },
    ]);
    await (await _prefs).setString(_key, encoded);
  }

  /// Records [id] as installed at [at] (defaults to now). No-ops if
  /// the id is already installed — repeated installs don't bump the
  /// timestamp, matching App-Store semantics where install date is
  /// first-install, not latest.
  ///
  /// [certHash] is for the privileged install path: when present,
  /// the cert hash verified by the install orchestrator is stamped
  /// alongside the install timestamp so the WebView's `_admin.exec`
  /// handler can read it back without a second lookup. Re-installing
  /// the same id is still a no-op — the cert hash for an existing
  /// install is updated by [updateCertHash].
  ///
  /// [bundleSha256] records the bytes that landed on disk; the launch
  /// path's auto-update check compares this against the catalog SHA to
  /// detect a developer's `sdk beta promote` rolling out.
  Future<void> install(
    String id, {
    DateTime? at,
    String? certHash,
    String? bundleSha256,
  }) async {
    final current = await load();
    if (current.containsKey(id)) return;
    current[id] = InstalledMiniAppRecord(
      installedAt: at ?? DateTime.now(),
      certHash: certHash,
      bundleSha256: bundleSha256,
    );
    await _save(current);
  }

  /// Stamp / overwrite the bundle SHA on an already-installed app.
  /// Used by the auto-update path: after re-extracting a new bundle
  /// over an existing install, this records the new SHA so the next
  /// launch's mismatch check sees the freshly-installed bytes as the
  /// installed truth.
  Future<void> updateBundleSha(String id, String? bundleSha256) async {
    final current = await load();
    final existing = current[id];
    if (existing == null) return;
    current[id] = InstalledMiniAppRecord(
      installedAt: existing.installedAt,
      certHash: existing.certHash,
      bundleSha256: bundleSha256,
    );
    await _save(current);
  }

  /// Read the recorded bundle SHA for [id], if any. Returns null when
  /// the app isn't installed OR when the install record predates SHA
  /// tracking (legacy v1/v2 records). The launch path treats null as
  /// "unknown — skip auto-update prompt."
  Future<String?> bundleShaFor(String id) async {
    final current = await load();
    return current[id]?.bundleSha256;
  }

  /// Stamp / overwrite the cert hash on an already-installed app.
  /// Used by the privileged-install pipeline when a cert rotates and
  /// the install record needs to point at the new verified hash; or
  /// when a regular mini-app turns into a privileged one mid-life.
  Future<void> updateCertHash(String id, String? certHash) async {
    final current = await load();
    final existing = current[id];
    if (existing == null) return;
    current[id] = InstalledMiniAppRecord(
      installedAt: existing.installedAt,
      certHash: certHash,
    );
    await _save(current);
  }

  Future<void> uninstall(String id) async {
    final current = await load();
    if (current.remove(id) != null) {
      await _save(current);
    }
  }

  Future<bool> isInstalled(String id) async {
    final current = await load();
    return current.containsKey(id);
  }

  /// Read the verified cert hash for [id], if any. The viewer's
  /// `_admin.exec` handler calls this so the dispatcher's
  /// `AdminSession.certHash` is the hash the install orchestrator
  /// verified.
  Future<String?> certHashFor(String id) async {
    final current = await load();
    return current[id]?.certHash;
  }
}

final miniAppInstallStorageProvider = Provider<MiniAppInstallStorage>((_) {
  return MiniAppInstallStorage(SharedPreferences.getInstance);
});

library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/mini_app_install_storage.dart';
import '../domain/mini_app.dart';
import 'mini_app_providers.dart';

/// Per-app update-availability descriptor.
@immutable
class MiniAppUpdateAvailable {
  const MiniAppUpdateAvailable({
    required this.app,
    required this.installedSha,
    required this.catalogSha,
  });

  final MiniApp app;
  final String installedSha;
  final String catalogSha;
}

/// Snapshot of the most recent check.
@immutable
class MiniAppUpdateCheckState {
  const MiniAppUpdateCheckState({
    required this.checking,
    required this.lastCheckedAt,
    required this.updatable,
    this.lastError,
  });

  final bool checking;
  final DateTime? lastCheckedAt;
  final List<MiniAppUpdateAvailable> updatable;
  final String? lastError;

  static const empty = MiniAppUpdateCheckState(
    checking: false,
    lastCheckedAt: null,
    updatable: <MiniAppUpdateAvailable>[],
  );

  MiniAppUpdateCheckState copyWith({
    bool? checking,
    DateTime? lastCheckedAt,
    List<MiniAppUpdateAvailable>? updatable,
    String? lastError,
    bool clearError = false,
  }) {
    return MiniAppUpdateCheckState(
      checking: checking ?? this.checking,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      updatable: updatable ?? this.updatable,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

const _prefsKey = 'mini_apps.update_checker.last_checked_at_ms';

class MiniAppUpdateCheckerNotifier extends Notifier<MiniAppUpdateCheckState> {
  @override
  MiniAppUpdateCheckState build() {
    // Hydrate the last-checked timestamp from SharedPreferences in the
    // background. Same lazy pattern as Saqr's RoamingPrefs.
    Future<void>(() async {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_prefsKey);
      if (ms != null) {
        state = state.copyWith(
          lastCheckedAt: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
        );
      }
    });
    return MiniAppUpdateCheckState.empty;
  }

  /// User-driven refresh + diff. Idempotent against rapid taps via
  /// the `checking` flag — re-tapping while a check is in flight is
  /// a no-op so the user doesn't queue parallel network calls.
  Future<void> checkNow() async {
    if (state.checking) return;
    state = state.copyWith(checking: true, clearError: true);
    try {
      // 1) Refresh the catalog. Surfaces network errors as exceptions
      //    here so the catch block can format a user-friendly message.
      await ref.read(miniAppCatalogProvider.notifier).refresh();

      // 2) Diff installed-vs-catalog SHA. Same logic
      //    `_autoUpdateIfNeeded` uses, just batched.
      final installed = ref.read(installedMiniAppsProvider);
      final storage = ref.read(miniAppInstallStorageProvider);
      final updatable = <MiniAppUpdateAvailable>[];
      for (final app in installed) {
        if (app.bundleSha256.isEmpty) continue; // legacy / unknown SHA
        final installedSha = await storage.bundleShaFor(app.id);
        if (installedSha == null) continue; // pre-SHA-tracking install
        if (installedSha.toLowerCase() == app.bundleSha256.toLowerCase()) {
          continue; // up to date
        }
        updatable.add(
          MiniAppUpdateAvailable(
            app: app,
            installedSha: installedSha,
            catalogSha: app.bundleSha256,
          ),
        );
      }

      // 3) Persist the timestamp so cross-cold-start "last checked"
      //    text doesn't lie.
      final now = DateTime.now().toUtc();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsKey, now.millisecondsSinceEpoch);

      state = state.copyWith(
        checking: false,
        lastCheckedAt: now,
        updatable: updatable,
      );
    } catch (e) {
      state = state.copyWith(checking: false, lastError: e.toString());
    }
  }
}

final miniAppUpdateCheckerProvider =
    NotifierProvider<MiniAppUpdateCheckerNotifier, MiniAppUpdateCheckState>(
      MiniAppUpdateCheckerNotifier.new,
    );

/// Convenience: per-app boolean — "does this installed app have a
/// newer version in the catalog?". Cheap synchronous lookup off the
/// already-computed [MiniAppUpdateCheckState] for tiles to badge.
bool miniAppUpdateAvailable(MiniAppUpdateCheckState s, String appId) {
  for (final u in s.updatable) {
    if (u.app.id == appId) return true;
  }
  return false;
}

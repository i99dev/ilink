import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/shell/shell_command.dart';
import '../../../kernel/shell/shell_tool_bridge_provider.dart';
import '../data/package_meta_reader.dart';
import '../domain/app_meta.dart';
import '../domain/app_target.dart';

/// Cache of meta keyed by target. Single AsyncNotifier holds a map
/// rather than a family — there's at most ONE actions sheet open at
/// a time, so the family lifecycle dance isn't worth the API
/// awkwardness in Riverpod 3.x.
class AppMetaCache extends AsyncNotifier<Map<String, AppMeta>> {
  @override
  Future<Map<String, AppMeta>> build() async => const {};

  /// Lazy resolve. If the entry isn't in the cache, kick off a read
  /// and stream the result.
  Future<AppMeta> get(AppTarget target) async {
    final key = keyOf(target);
    final current = state.value;
    if (current != null && current.containsKey(key)) return current[key]!;
    return _readAndStore(target);
  }

  /// Force a re-read. Called after a successful action so the sheet
  /// reflects truth instead of the optimistic projection.
  Future<void> refresh(AppTarget target) async {
    await _readAndStore(target);
  }

  /// Optimistic patch. Returns the snapshot before the patch so the
  /// caller can roll back on failure.
  AppMeta patch(AppTarget target, AppMeta Function(AppMeta) f) {
    final key = keyOf(target);
    final current = state.value ?? const <String, AppMeta>{};
    final pre = current[key] ?? AppMeta.unknown(key);
    final next = f(pre);
    state = AsyncData({...current, key: next});
    return pre;
  }

  /// Restore a snapshot — rollback path for failed writes.
  void restore(AppTarget target, AppMeta snapshot) {
    final key = keyOf(target);
    final current = state.value ?? const <String, AppMeta>{};
    state = AsyncData({...current, key: snapshot});
  }

  Future<AppMeta> _readAndStore(AppTarget target) async {
    final coord = ref.read(shellOpsCoordinatorProvider);
    final key = keyOf(target);
    AppMeta meta;
    if (target is NativeAppTarget) {
      Future<String?> safe(String cacheKey, List<String> argv) async {
        try {
          return await coord.read(ShellCommand(argv, cacheKey: cacheKey));
        } catch (e) {
          if (kDebugMode) debugPrint('app_meta read $cacheKey failed: $e');
          return null;
        }
      }

      final pkg = target.packageName;
      final results = await Future.wait([
        safe('dumpsys package $pkg', ['dumpsys', 'package', pkg]),
        safe('dumpsys deviceidle whitelist', const [
          'dumpsys',
          'deviceidle',
          'whitelist',
        ]),
        safe('dumpsys activity recents', const [
          'dumpsys',
          'activity',
          'recents',
        ]),
      ]);
      final pkgDump = results[0];
      final whitelistDump = results[1];
      final recentDump = results[2];

      meta = AppMeta.unknown(pkg);
      if (pkgDump != null) {
        meta = PackageMetaReader.parsePackageDump(pkgDump, packageName: pkg);
      }
      if (whitelistDump != null) {
        final set = PackageMetaReader.parseDozeWhitelist(whitelistDump);
        meta = meta.copyWith(inDozeWhitelist: set.contains(pkg));
      }
      if (recentDump != null) {
        final tasks = PackageMetaReader.parseRunningTasks(recentDump);
        final tid = tasks[pkg];
        if (tid != null) meta = meta.copyWith(runningTaskId: tid);
      }
    } else {
      // Mini-app: stub. Eligibility on the registry filters every
      // shell-driven action when the target is a mini-app.
      meta = AppMeta.unknown(key);
    }
    final current = state.value ?? const <String, AppMeta>{};
    state = AsyncData({...current, key: meta});
    return meta;
  }

  static String keyOf(AppTarget target) => switch (target) {
    NativeAppTarget(:final packageName) => packageName,
    MiniAppTarget(:final appId) => appId,
  };
}

final appMetaCacheProvider =
    AsyncNotifierProvider<AppMetaCache, Map<String, AppMeta>>(AppMetaCache.new);

/// Per-target accessor that the sheet watches. Returns
/// `AsyncValue.loading` until the first read for `target` resolves.
/// Side-effect: triggers a lazy load if the entry is absent.
final appMetaForTargetProvider = Provider.autoDispose
    .family<AsyncValue<AppMeta>, AppTarget>((ref, target) {
      final cache = ref.watch(appMetaCacheProvider);
      final key = AppMetaCache.keyOf(target);
      return cache.when(
        loading: () => const AsyncValue.loading(),
        error: (e, st) => AsyncValue.error(e, st),
        data: (m) {
          final hit = m[key];
          if (hit != null) return AsyncValue.data(hit);
          Future.microtask(
            () => ref.read(appMetaCacheProvider.notifier).get(target),
          );
          return const AsyncValue.loading();
        },
      );
    });

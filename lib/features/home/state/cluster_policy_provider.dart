import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'installed_apps_provider.dart';

/// Riverpod surface over the native `ClusterLaunchPolicy` (the single
/// source of truth for "fresh-launch this app on the cluster instead
/// of same-pid move-stack"). The rule itself lives ONLY in native —
/// nothing here re-implements it; we ask and render the answer.
///
/// Two providers, two jobs:
///   * [clusterFreshLaunchProvider] — the effective verdict for the
///     currently-installed apps, resolved in ONE batched native
///     `classify` per app-list refresh. Badge widgets watch this and
///     test membership; no per-icon channel hops.
///   * [clusterPolicyUserAddedProvider] — the USER-added set for the
///     settings screen (rule-matched apps like ReVanced are implicit
///     and never appear here). Mutations flow through the controller
///     so the badge provider is invalidated and every surface
///     refreshes together.

/// Effective fresh-launch-only set, scoped to installed apps.
/// `autoDispose` (mirrors [installedAppsProvider]) — recomputed when
/// the app list changes or the controller invalidates it.
final clusterFreshLaunchProvider = FutureProvider.autoDispose<Set<String>>((
  ref,
) async {
  final apps = await ref.watch(installedAppsProvider.future);
  if (apps.isEmpty) return <String>{};
  final bridge = ref.watch(pkgBridgeProvider);
  return bridge.clusterPolicyClassify(
    apps.map((a) => a.packageName).toList(growable: false),
  );
});

/// The USER-added package set. Single [AsyncNotifier] (mirrors
/// `AppMetaCache`) — there is at most one settings screen open, so a
/// family is unwarranted. Mutations are write-through to native and
/// invalidate [clusterFreshLaunchProvider] so badges update live.
class ClusterPolicyController extends AsyncNotifier<Set<String>> {
  @override
  Future<Set<String>> build() async {
    final bridge = ref.watch(pkgBridgeProvider);
    return (await bridge.clusterPolicyAdded()).toSet();
  }

  Future<void> add(String packageName) =>
      _mutate(() => ref.read(pkgBridgeProvider).clusterPolicyAdd(packageName));

  Future<void> remove(String packageName) => _mutate(
    () => ref.read(pkgBridgeProvider).clusterPolicyRemove(packageName),
  );

  Future<void> _mutate(Future<List<String>> Function() op) async {
    final next = await op();
    state = AsyncData(next.toSet());
    // Effective verdict (badges) derives from the user set + the
    // native rule — recompute it from the source of truth.
    ref.invalidate(clusterFreshLaunchProvider);
  }
}

final clusterPolicyUserAddedProvider =
    AsyncNotifierProvider<ClusterPolicyController, Set<String>>(
      ClusterPolicyController.new,
    );

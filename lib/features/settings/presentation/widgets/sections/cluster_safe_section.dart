import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../cluster_patch/cluster_patch_bridge.dart';
import '../../../../cluster_patch/cluster_patch_flow.dart';
import '../../../../home/presentation/widgets/circle_app_icon.dart';
import '../../../../home/state/cluster_policy_provider.dart';
import '../../../../home/state/installed_apps_provider.dart';
import '../section_scaffold.dart';

/// "Cluster apps" — lets the user manage which apps the car
/// fresh-launches on the driver cluster instead of same-pid
/// move-stack (apps that bounce/crash on the cross-display recreate).
///
/// Single source of truth is native `ClusterLaunchPolicy`; this
/// screen only renders + edits it:
///   * [clusterFreshLaunchProvider] — effective verdict (rule OR
///     user). Drives the per-row state + which rows are locked.
///   * [clusterPolicyUserAddedProvider] — the USER set; toggling a
///     non-rule app calls the controller, which write-throughs to
///     native and invalidates the effective provider so the home
///     badges refresh together.
///
/// Rule-matched apps (ReVanced/-patched) are shown ON + locked with
/// an "Auto" tag — the rule always applies; v1 doesn't support
/// un-setting them (it would re-introduce a guaranteed crash).
class ClusterSafeSection extends ConsumerStatefulWidget {
  const ClusterSafeSection({super.key});

  @override
  ConsumerState<ClusterSafeSection> createState() => _ClusterSafeSectionState();
}

class _ClusterSafeSectionState extends ConsumerState<ClusterSafeSection> {
  final _searchCtl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchCtl.addListener(
      () => setState(() => _query = _searchCtl.text.trim().toLowerCase()),
    );
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final appsAsync = ref.watch(installedAppsProvider);
    final fresh =
        ref.watch(clusterFreshLaunchProvider).value ?? const <String>{};
    final userAdded =
        ref.watch(clusterPolicyUserAddedProvider).value ?? const <String>{};
    final patched =
        ref.watch(patchedPackagesProvider).value ?? const <String>{};

    return SectionScaffold(
      title: t.sectionClusterTitle,
      subtitle: t.sectionClusterSubtitleShort,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t.clusterSectionHeader,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _searchCtl,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: t.clusterSectionSearchHint,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 12),
          appsAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, _) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                t.clusterSectionError,
                style: TextStyle(color: cs.error),
              ),
            ),
            data: (apps) {
              final filtered = _query.isEmpty
                  ? apps
                  : apps
                        .where(
                          (a) =>
                              a.label.toLowerCase().contains(_query) ||
                              a.packageName.toLowerCase().contains(_query),
                        )
                        .toList(growable: false);
              if (filtered.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    t.clusterSectionEmpty,
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                );
              }
              return Column(
                children: [
                  for (final app in filtered)
                    _AppRow(
                      label: app.label.isEmpty ? app.packageName : app.label,
                      packageName: app.packageName,
                      // Effective ON if rule OR user added it.
                      isFresh: fresh.contains(app.packageName),
                      // Rule-locked when effective but NOT user-added
                      // (the rule, e.g. ReVanced, is what set it).
                      ruleLocked:
                          fresh.contains(app.packageName) &&
                          !userAdded.contains(app.packageName),
                      isPatched: patched.contains(app.packageName),
                      isSystem: app.isSystem,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// The cluster capability of an app, computed from cheap signals (no probe).
enum _Cap { patched, system, onCluster, patch }

class _AppRow extends ConsumerWidget {
  const _AppRow({
    required this.label,
    required this.packageName,
    required this.isFresh,
    required this.ruleLocked,
    required this.isPatched,
    required this.isSystem,
  });

  final String label;
  final String packageName;
  final bool isFresh;
  final bool ruleLocked;
  final bool isPatched;
  final bool isSystem;

  _Cap get _cap => isPatched
      ? _Cap.patched
      : isSystem
      ? _Cap.system
      : isFresh
      ? _Cap.onCluster
      : _Cap.patch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final initial = label.isEmpty ? '?' : label.characters.first.toUpperCase();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAppIcon(
            fallback: initial,
            diameter: 40,
            shadow: false,
            clusterBadge: isFresh,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  packageName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                ),
              ],
            ),
          ),
          // At-a-glance cluster capability (cheap, no probe): Patched / System /
          // On cluster / Patch.
          _CapabilityChip(cap: _cap),
          const SizedBox(width: 8),
          // Action: a VISIBLE Undo when patched; the Patch button when it's a
          // patch candidate; nothing for system apps (can't patch).
          if (isPatched)
            OutlinedButton.icon(
              onPressed: () => patchAppForCluster(
                context: context,
                packageName: packageName,
                label: label,
              ),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                foregroundColor: cs.onSurfaceVariant,
              ),
              icon: const Icon(Icons.undo, size: 16),
              label: const Text('Undo'),
            )
          else if (_cap == _Cap.patch)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Patch for cluster',
              icon: const Icon(Icons.build_outlined, size: 20),
              onPressed: () => patchAppForCluster(
                context: context,
                packageName: packageName,
                label: label,
              ),
            ),
          const SizedBox(width: 8),
          if (ruleLocked)
            Tooltip(
              message: t.clusterSectionAutoHelp,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  t.clusterSectionAuto,
                  style: TextStyle(
                    color: cs.onTertiaryContainer,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            )
          else
            Tooltip(
              message: t.clusterSectionToggleHelp,
              child: Switch(
                value: isFresh,
                onChanged: (on) {
                  final ctl = ref.read(clusterPolicyUserAddedProvider.notifier);
                  if (on) {
                    ctl.add(packageName);
                  } else {
                    ctl.remove(packageName);
                  }
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// At-a-glance cluster capability. Patched / On-cluster / System show a chip;
/// a plain patch-candidate shows nothing (the Patch button conveys it) so the
/// list stays quiet.
class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({required this.cap});
  final _Cap cap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (IconData, String, Color, Color)? spec = switch (cap) {
      _Cap.patched => (
        Icons.check_circle,
        'Patched',
        cs.primaryContainer,
        cs.onPrimaryContainer,
      ),
      _Cap.onCluster => (
        Icons.cast_connected,
        'On cluster',
        cs.tertiaryContainer,
        cs.onTertiaryContainer,
      ),
      _Cap.system => (
        Icons.lock_outline,
        'System',
        cs.surfaceContainerHighest,
        cs.onSurfaceVariant,
      ),
      _Cap.patch => null,
    };
    if (spec == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: spec.$3,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(spec.$1, size: 13, color: spec.$4),
          const SizedBox(width: 3),
          Text(
            spec.$2,
            style: TextStyle(
              color: spec.$4,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Gate-probe screen — operator-only validation harness for the live
/// car-data read surface.
///
/// Enumerates the SDK's full known-names set
/// (`bydStatusLabelToCatalog.values` — ~150 names, the same brand
/// label map `gateSnapshotProvider` uses). On first open the screen
/// asks the SDK to batch-fetch + push-subscribe every name so the
/// rows populate even if no widget watches them. NO hardcoded field
/// list — adding a label to the brand map is enough to make it
/// appear here.
///
/// Each row's value re-renders live via `ref.watchFeatureInt(name)`
/// — the same per-name push subscription the dashboard tiles use.
/// Catalog metadata (description, unit, semantics) is pulled from
/// the per-brand catalog asset (`assets/byd/catalog_meta.yaml` for
/// BYD); rows fall back to a humanised name when the metadata is
/// silent on a given entry.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../../sdk/brands/byd/byd_status_labels.dart';
import '../../../../../../sdk/car/catalog.dart';
import '../../../../../../sdk/car/client.dart';
import '../../../../../../sdk/car/feature.dart';
import '../../../../../../sdk/car/providers.dart';
import '../../../../../../sdk/car/widget_helpers.dart';

class GateProbeScreen extends ConsumerWidget {
  const GateProbeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Trigger boot-up of the full known set — fetch every name
    // we know about + push-subscribe them. Lives outside the
    // FutureProvider so it fires once per screen open.
    ref.watch(_probeWarmupProvider);

    final featuresAsync = ref.watch(_liveFeaturesProvider);
    final catalogAsync = ref.watch(carCatalogProvider);
    final pushDiag = ref
        .watch(_pushDiagnosticsProvider)
        .maybeWhen(data: (m) => m, orElse: () => const <String, dynamic>{});
    return featuresAsync.when(
      loading: () =>
          const _Scaffold(child: Center(child: CircularProgressIndicator())),
      error: (e, _) => _Scaffold(child: Center(child: Text('Error: $e'))),
      data: (features) {
        return _Body(
          features: features,
          catalog: catalogAsync.maybeWhen(data: (c) => c, orElse: () => null),
          pushDiag: pushDiag,
        );
      },
    );
  }
}

/// Full set of names the gate-probe inspects. Sourced from the brand
/// label map (the same map `gateSnapshotProvider` materialises a
/// CarGate from), de-duped. NOT a hardcoded list of field names —
/// adding a label here is the only place to register a new entry.
final _knownNames = bydStatusLabelToCatalog.values.toSet().toList()..sort();

/// Push-pipeline diagnostic — re-emits every 2 s.
/// Surfaces:
///   * `frameworkPushFramesReceived` — counter incremented every time
///     the BYD framework calls onPostEvent on any of our BydPushDevice
///     instances. Zero after car activity = framework isn't pushing
///     to us at all.
///   * `sdkPushSubscribedNames` — how many names the SDK has
///     registered InAppPushManager subscriptions for.
final _pushDiagnosticsProvider =
    StreamProvider.autoDispose<Map<String, dynamic>>((ref) async* {
      // ignore: invalid_use_of_internal_member — registryStats is exposed
      // through CarClient.registryStats for diagnostics.
      Future<Map<String, dynamic>> read() async {
        try {
          return await ref.read(carClientProvider).registryStats();
        } catch (_) {
          return const {};
        }
      }

      yield await read();
      await for (final _ in Stream<void>.periodic(const Duration(seconds: 2))) {
        yield await read();
      }
    });

/// Boot-up: ask the SDK to batch-fetch + push-subscribe every name in
/// `_knownNames`. Fires once on screen mount; subsequent opens hit
/// the cache (BydClient dedupes both fetches and subscriptions).
final _probeWarmupProvider = FutureProvider.autoDispose<void>((ref) async {
  final client = ref.watch(carClientProvider);
  // Subscribe FIRST so any push frame that arrives during the fetch
  // populates the cache. The fetch returns whatever the daemon has
  // synchronously available; the push subscription catches later
  // changes.
  unawaited(_subscribePushAll(client));
  // The fetch itself is for the "show me everything live RIGHT NOW"
  // payload — fire-and-forget, the live re-renders pick up its
  // results via the per-name watchers.
  unawaited(client.liveFeatures().then((_) {}));
});

Future<void> _subscribePushAll(CarClient client) async {
  // CarClient.watch() registers a push subscription as a side
  // effect (BydClient._ensurePushSubscribed). One listen-then-
  // immediate-cancel is enough — the subscription on the host
  // persists.
  for (final name in _knownNames) {
    final sub = client.watch(name).listen(null);
    await sub.cancel();
  }
}

/// Live snapshot — re-emits every 2 s so newly-arriving names show
/// up. Per-row value updates flow through `ref.watchFeatureInt(name)`
/// in [_NamespacePane], independent of this poll cadence.
final _liveFeaturesProvider = StreamProvider.autoDispose<Map<String, int>>((
  ref,
) async* {
  yield await _read(ref);
  await for (final _ in Stream<void>.periodic(const Duration(seconds: 2))) {
    yield await _read(ref);
  }
});

Future<Map<String, int>> _read(Ref ref) {
  return ref.read(carClientProvider).liveFeatures();
}

class _Scaffold extends StatelessWidget {
  const _Scaffold({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Gate probe')),
    body: child,
  );
}

class _Body extends StatelessWidget {
  const _Body({
    required this.features,
    required this.catalog,
    required this.pushDiag,
  });
  final Map<String, int> features;
  final CarCatalog? catalog;
  final Map<String, dynamic> pushDiag;

  @override
  Widget build(BuildContext context) {
    // Group the FULL known-names set by namespace prefix — every
    // catalog name in the brand label map gets a row regardless of
    // whether it's live yet. Live ones render green; not-yet-
    // received ones render grey so the operator sees the to-do
    // list of names the host isn't publishing.
    final byNamespace = <String, List<String>>{};
    for (final name in _knownNames) {
      final dot = name.indexOf('.');
      final ns = dot < 0 ? 'Misc' : name.substring(0, dot);
      byNamespace.putIfAbsent(ns, () => []).add(name);
    }
    // Sort namespaces by entry count desc — biggest tabs first.
    final namespaces = byNamespace.keys.toList()
      ..sort(
        (a, b) => byNamespace[b]!.length.compareTo(byNamespace[a]!.length),
      );

    return DefaultTabController(
      length: namespaces.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Gate probe'),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(72),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SummaryStrip(
                  liveCount: features.length,
                  knownCount: _knownNames.length,
                  pushFrames:
                      (pushDiag['frameworkPushFramesReceived'] as num?)
                          ?.toInt() ??
                      0,
                  pushSubs:
                      (pushDiag['sdkPushSubscribedNames'] as num?)?.toInt() ??
                      0,
                ),
                TabBar(
                  isScrollable: true,
                  tabs: [
                    for (final ns in namespaces)
                      Tab(
                        text:
                            '$ns\n${_liveInNamespace(features, byNamespace[ns]!)}/${byNamespace[ns]!.length}',
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        body: TabBarView(
          children: [
            for (final ns in namespaces)
              _NamespacePane(names: byNamespace[ns]!, catalog: catalog),
          ],
        ),
      ),
    );
  }

  static int _liveInNamespace(Map<String, int> features, List<String> names) {
    var n = 0;
    for (final name in names) {
      if (features.containsKey(name)) n++;
    }
    return n;
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({
    required this.liveCount,
    required this.knownCount,
    required this.pushFrames,
    required this.pushSubs,
  });
  final int liveCount;
  final int knownCount;
  final int pushFrames;
  final int pushSubs;

  @override
  Widget build(BuildContext context) {
    final grey = (knownCount - liveCount).clamp(0, knownCount);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Text(
            '$liveCount / $knownCount fields live',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: Color(0xFF2EA66B),
            ),
          ),
          const SizedBox(width: 16),
          // Framework push-frame counter — non-zero proves the BYD
          // framework's onPostEvent is reaching us. Zero after some
          // car activity = the registration surface is wrong.
          Text(
            'push: $pushFrames frames · $pushSubs subs',
            style: TextStyle(
              fontSize: 12,
              color: pushFrames > 0
                  ? const Color(0xFF2EA66B)
                  : const Color(0xFFD9A227),
            ),
          ),
          const Spacer(),
          Text('$grey grey', style: const TextStyle(color: Color(0xFF6E6E6E))),
        ],
      ),
    );
  }
}

class _NamespacePane extends ConsumerWidget {
  const _NamespacePane({required this.names, required this.catalog});
  final List<String> names;
  final CarCatalog? catalog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Sort within a namespace by name — stable, scannable.
    final sorted = [...names]..sort();
    return ListView.separated(
      itemCount: sorted.length,
      separatorBuilder: (_, _) => const Divider(height: 1, thickness: 0.5),
      itemBuilder: (_, i) {
        final name = sorted[i];
        // Per-row push subscription. ref.watchFeatureInt triggers
        // BydClient._ensurePushSubscribed on first listen, so opening
        // this screen also kicks off live-update flow for any name
        // the boot warm set didn't cover.
        final live = ref.watchFeatureInt(name);
        final meta = catalog?.feature(name);
        return _Row(name: name, value: live, meta: meta);
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.name, required this.value, required this.meta});
  final String name;
  final int? value;
  final CarFeature? meta;

  @override
  Widget build(BuildContext context) {
    final desc = meta?.description ?? _humanise(name);
    final unit = meta?.unit;
    final semantics = meta?.semantics;
    final isLive = value != null;
    return ListTile(
      dense: true,
      leading: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: isLive
              ? const Color(0xFF2EA66B) // green: live
              : const Color(0xFF6E6E6E), // grey: never received
          shape: BoxShape.circle,
        ),
      ),
      title: Text(desc, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        semantics == null ? name : '$name  ·  $semantics',
        style: const TextStyle(fontSize: 11, color: Color(0xFF888888)),
      ),
      trailing: Text(
        !isLive ? '—' : (unit == null ? '$value' : '$value $unit'),
        style: TextStyle(
          fontSize: 14,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
          color: isLive ? null : const Color(0xFF6E6E6E),
        ),
      ),
    );
  }

  /// Strip the namespace prefix and titleise the constant name.
  /// `Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR` →
  /// "Bodywork left hand front door".
  static String _humanise(String name) {
    final dot = name.indexOf('.');
    final tail = dot < 0 ? name : name.substring(dot + 1);
    final lower = tail.toLowerCase().replaceAll('_', ' ');
    if (lower.isEmpty) return name;
    return lower[0].toUpperCase() + lower.substring(1);
  }
}

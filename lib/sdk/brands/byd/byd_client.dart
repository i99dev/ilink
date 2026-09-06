/// BYD adapter for the brand-agnostic [CarClient].
///
/// Wraps the BYD bridge (CarBridge MethodChannel +
/// `ilink/car/registry` EventChannel). New brands (Geely, NIO,
/// Tesla) will mirror this shape with their own MethodChannel /
/// EventChannel pair.
///
/// **Catalog-first, registry-optional**: boot warmup pulls the
/// dashboard's known set of names (everything `bydStatusLabelToCatalog`
/// declares) in a SINGLE batched daemon round-trip via
/// `getValuesByName`. Each name is resolved by the host through
/// `BydAutoFeatureIdsCatalog` directly — the AutoCarRegistry is no
/// longer in the data path. The registry survives only as the
/// observability surface behind the Auto Registry diagnostic screen.
///
/// Why this shape:
///   * Boot is fast: ~30 ms to fetch ~100 names vs. waiting for a
///     5–10 s brute-force probe over 21k entries.
///   * No "Registry is empty" failure mode — the SDK never depends
///     on the registry being built.
///   * Unknown names still work: the [_scheduleFallback] microtask
///     batches any first-watch outside the warm set.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'package:ilink/sdk/car/_transport/action_contract.dart'
    as action_contract;
import 'package:ilink/sdk/car/_transport/car_bridge.dart';
import 'package:ilink/sdk/car/_transport/car_transport.dart';
import '../../car/car_caller.dart';
import '../../car/client.dart';
import '../../car/gated_dispatcher.dart';
import 'byd_common_derives.dart';
import 'byd_status_labels.dart';
import 'dilink/dilink.dart';

class BydClient implements CarClient {
  BydClient(Ref ref)
    : _ref = ref,
      _transport = ref.watch(carBridgeProvider),
      _dilink = _selectDilinkAdapter() {
    _initInstance();
  }

  /// Test-only constructor that takes the transport directly. Skips
  /// the push EventChannel + disk LKV (no platform plugins in unit
  /// tests) so SDK-shape tests can run without Flutter binding setup.
  @visibleForTesting
  BydClient.forTest(
    CarTransport transport, {
    DilinkVersion forceDilink = DilinkVersion.dilink_5_1,
  }) : _ref = null,
       _transport = transport,
       _dilink = _selectDilinkAdapter(force: forceDilink) {
    _commonDeriveHandles = const [];
    // Skip _attachPushStream + _loadDiskLkv intentionally — both rely
    // on platform plugins that aren't bound in `flutter test`. The
    // tests use handlePushForTest() to simulate inbound frames.
  }

  /// Centralised adapter selection — runs once per client construct.
  /// Ensures the [BydDilinkAdapter] registry is initialised before
  /// the first detect/forTesting call.
  static BydDilinkAdapter _selectDilinkAdapter({DilinkVersion? force}) {
    ensureBydDilinkAdaptersRegistered();
    return BydDilinkAdapter.detect(force: force);
  }

  /// The DiLink-version-specific policy adapter. Final — chosen at
  /// construct, fixed for the lifetime of the client. Consumers (push
  /// pipeline, cluster-pixel writer, asset loader) read flags directly:
  ///
  /// ```dart
  /// if (client.dilink.clusterPixelSignatureGated) return skipClusterWrite;
  /// ```
  ///
  /// Hot-path dispatch is zero-cost (final field read).
  final BydDilinkAdapter _dilink;
  BydDilinkAdapter get dilink => _dilink;

  void _initInstance() {
    unawaited(_loadDiskLkv());
    _attachPushStream();
    // Install the brand-bundled derived signals so every consumer
    // can reach `derived.any_door_open` / `derived.total_range_km`
    // etc. without re-rolling the compute. Lifetime = client's.
    _commonDeriveHandles = installBydCommonDerives(this);
  }

  late List<DerivedHandle> _commonDeriveHandles;

  final Ref? _ref;
  final CarTransport _transport;

  /// Hot in-memory cache — push frames update in place.
  final _values = <String, int>{};

  /// Per-name timestamp of the last update. Used by [freshness] so
  /// tiles can render a stale chip after a daemon disconnect.
  final _lastUpdateAt = <String, DateTime>{};

  /// Per-name broadcast controllers — lazy on first watch.
  final _watchers = <String, StreamController<int?>>{};

  /// Single broadcast that fires once per push frame regardless of
  /// field — snapshot-style consumers (typed gate builder, mini-app
  /// fan-out) subscribe once here instead of N per-name watches.
  // Emits the changed catalog name per push frame, or '' for a
  // batch/unknown frame (boot seed, persist-restore, multi-name recompute)
  // — see [changes].
  final _changes = StreamController<String>.broadcast();

  StreamSubscription<dynamic>? _pushSub;

  bool _seeded = false;
  Future<void>? _seedingFuture;

  /// Names that need a fallback fetch — collected within a single
  /// microtask, dispatched as one bulk daemon call. Eliminates the
  /// N+1 problem of N widgets each triggering N sequential fetches
  /// at boot.
  final _pendingFallbackNames = <String>{};
  Completer<void>? _fallbackBatchCompleter;

  /// Names we've already asked the host to push-subscribe. Push
  /// subscriptions are registry-free (host-side
  /// AutoFeatureService.subscribePushByName resolves via catalog +
  /// WARM_DT) so they work even when AutoCarRegistry hasn't built.
  final _subscribedPushNames = <String>{};

  // ── Public CarClient API ─────────────────────────────────────────

  @override
  int? value(String name) => _values[name];

  @override
  Future<int?> refreshValue(String name) async {
    // Targeted live read of one signal — same primitive the warm-set seed
    // uses, scoped to [name]. Updates the hot cache + freshness so a later
    // `value(name)` / `freshness(name)` reflects it. Throws propagate to the
    // caller (e.g. the stationary gate decides fail-open on a dead daemon).
    final fresh = await _transport.getValuesByName([name]);
    final v = fresh[name];
    if (v != null) {
      _values[name] = v;
      _lastUpdateAt[name] = DateTime.now();
      _watchers[name]?.add(v);
    }
    return _values[name];
  }

  @override
  Stream<int?> watch(String name) async* {
    await _ensureSeeded();
    final ctl = _watchers.putIfAbsent(
      name,
      () => StreamController<int?>.broadcast(),
    );
    // Make sure live updates flow for this name. The boot seed
    // covers the warm set; everything else gets subscribed lazily
    // here so its changes reach the UI without an app restart.
    unawaited(_ensurePushSubscribed([name]));
    // For state-change-only signals: when boot warmup didn't catch a
    // name (e.g. door already closed at boot — registry probe returned
    // sentinel, daemon returns null) `_values[name]` is still missing.
    // Schedule a BATCHED fallback — every name that needs one within
    // the current microtask gets dispatched in a single
    // getValuesByName call.
    if (_values[name] == null) {
      await _scheduleFallback(name);
    }
    yield _values[name];
    yield* ctl.stream;
  }

  /// Coalesce multiple `watch()` callers' fallback fetches into
  /// one bulk daemon round-trip. The first caller in a microtask
  /// schedules the dispatch; subsequent callers add to the same
  /// pending set + await the same Completer.
  Future<void> _scheduleFallback(String name) async {
    _pendingFallbackNames.add(name);
    var completer = _fallbackBatchCompleter;
    if (completer == null) {
      completer = Completer<void>();
      _fallbackBatchCompleter = completer;
      // Drain on the next microtask — gives sibling watchers in
      // the same build pass time to add their names to the batch.
      scheduleMicrotask(() async {
        final names = _pendingFallbackNames.toList(growable: false);
        _pendingFallbackNames.clear();
        _fallbackBatchCompleter = null;
        try {
          final fresh = await _transport.getValuesByName(names);
          final now = DateTime.now();
          fresh.forEach((k, v) {
            _values[k] = v;
            _lastUpdateAt[k] = now;
            _watchers[k]?.add(v);
          });
          if (fresh.isNotEmpty && _changes.hasListener) _changes.add('');
          if (fresh.isNotEmpty) _schedulePersist();
        } catch (_) {
          // Bulk fetch failed — values stay null, widgets render
          // their "no data" branch. The next push frame (if any)
          // still wakes the per-name controller.
        }
        completer!.complete();
      });
    }
    return completer.future;
  }

  @override
  Future<Map<String, int>> liveFeatures() async {
    await _ensureSeeded();
    return Map.unmodifiable(_values);
  }

  @override
  Map<String, int> liveFeaturesSync() => Map.unmodifiable(_values);

  @override
  Future<Map<String, int>> allCatalogNames() {
    return _transport.allKnownFeatures();
  }

  @override
  Future<Map<String, Object?>> invoke(
    String actionId, [
    Map<String, Object?> args = const {},
  ]) => _transport.runAction(actionId, args);

  @override
  Future<Map<String, Object?>> dispatch(
    String actionId, {
    Map<String, Object?> args = const {},
    CarCaller? caller,
  }) {
    // Route through the app's gated dispatcher (audit / integrity /
    // rate-limit / stationary checks) when installed; otherwise fall
    // back to the raw transport path. The app overrides
    // [gatedDispatcherProvider] at boot — see lib/main.dart. Tests
    // that don't wire the gate get the same behaviour as production
    // with the gate turned off (raw runAction).
    final ref = _ref;
    if (ref != null) {
      final gated = ref.read(gatedDispatcherProvider);
      if (gated != null) {
        return gated(actionId, args.cast<String, dynamic>(), caller: caller);
      }
    }
    return _transport
        .runAction(actionId, args.cast<String, dynamic>())
        .then((m) => m.cast<String, Object?>());
  }

  @override
  Future<DispatchResult> dispatchAndConfirm(
    String actionId, {
    required String name,
    required bool Function(int) expect,
    Duration timeout = const Duration(seconds: 5),
    Map<String, Object?> args = const {},
    CarCaller? caller,
  }) async {
    // Subscribe BEFORE dispatch so a fast push frame between dispatch
    // landing and our listener arming doesn't slip through.
    final completer = Completer<int>();
    final sub = watch(name).listen((v) {
      if (v != null && expect(v) && !completer.isCompleted) {
        completer.complete(v);
      }
    });
    try {
      // First-frame from watch() emits the current cached value
      // synchronously — short-circuit if we're already in the
      // expected state (idempotent dispatch).
      final cached = value(name);
      if (cached != null && expect(cached) && !completer.isCompleted) {
        completer.complete(cached);
      }
      final dispatchResult = await dispatch(
        actionId,
        args: args,
        caller: caller,
      );
      try {
        final observed = await completer.future.timeout(timeout);
        return DispatchResult(
          result: dispatchResult,
          confirmed: true,
          observedValue: observed,
        );
      } on TimeoutException {
        return DispatchResult(
          result: dispatchResult,
          confirmed: false,
          observedValue: null,
        );
      }
    } finally {
      await sub.cancel();
    }
  }

  @override
  Stream<String> changes() => _changes.stream;

  @override
  Duration? freshness(String name) {
    final at = _lastUpdateAt[name];
    if (at == null) return null;
    return DateTime.now().difference(at);
  }

  // ── Diagnostics + orthogonal surfaces ───────────────────────────

  @override
  Future<Map<String, dynamic>> daemonStatus() => _transport.daemonStatus();

  @override
  Future<Map<String, dynamic>> identity({bool localOnly = false}) =>
      localOnly ? _transport.carIdentityLocalOnly() : _transport.carIdentity();

  @override
  Future<List<String>> knownActions() => _transport.knownActions();

  @override
  Future<Map<String, dynamic>> registryStats() => _transport.registryStats();

  @override
  Future<Map<String, dynamic>> acTransact(
    String service,
    String method, {
    Map<String, dynamic>? args,
  }) => _transport.acTransact(service, method, args: args);

  @override
  Stream<Map<String, dynamic>> observeFamily(String family) {
    // ContentProvider observation surface was removed with the v2
    // mini-app bridge (see deletion of
    // `lib/sdk/car/_transport/car_content_provider_channel.dart`).
    // No live consumer remains in-app; the abstract member is kept
    // on [CarClient] for ABI compatibility with future brand
    // adapters. Returns an empty stream — current-state seeding
    // still works via [readFamily] which goes through the transport.
    return const Stream.empty();
  }

  @override
  Future<Map<String, dynamic>?> readFamily(String family) =>
      _transport.readContentProvider(family);

  // ── Connection state ────────────────────────────────────────────

  final _connectionState = StreamController<DaemonState>.broadcast();
  DaemonState _currentConnectionState = DaemonState.connected;

  @override
  Stream<DaemonState> connectionState() async* {
    yield _currentConnectionState;
    yield* _connectionState.stream;
  }

  @override
  DaemonState get currentConnectionState => _currentConnectionState;

  /// Internal — flip the broadcast state. Called from
  /// [_pollDaemonHealth] and from anywhere a transport call surfaces a
  /// connectivity hint.
  void _setConnectionState(DaemonState s) {
    if (_currentConnectionState == s) return;
    _currentConnectionState = s;
    _connectionState.add(s);
  }

  Timer? _healthTimer;
  void _startHealthPoll() {
    if (_healthTimer != null) return;
    // 10 s cadence — a transient ping miss flips us to reconnecting
    // immediately; two consecutive misses mean disconnected.
    _healthTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      try {
        final m = await _transport.daemonStatus().timeout(
          const Duration(seconds: 3),
        );
        final ok = m['daemon'] == true || m['mock'] == true;
        _setConnectionState(
          ok ? DaemonState.connected : DaemonState.reconnecting,
        );
      } catch (_) {
        _setConnectionState(
          _currentConnectionState == DaemonState.reconnecting
              ? DaemonState.disconnected
              : DaemonState.reconnecting,
        );
      }
    });
  }

  // ── Derived signals ─────────────────────────────────────────────

  /// Per-derived-name compute fns + their declared sources. The push
  /// listener walks this on every frame and recomputes any derived
  /// whose source changed.
  final _derivedCompute = <String, int? Function(Map<String, int?>)>{};
  final _derivedSources = <String, List<String>>{};
  final _derivedSourceIndex = <String, Set<String>>{}; // source → derived names

  @override
  DerivedHandle derive({
    required String name,
    required List<String> sources,
    required int? Function(Map<String, int?> sources) compute,
  }) {
    _derivedCompute[name] = compute;
    _derivedSources[name] = List.unmodifiable(sources);
    for (final s in sources) {
      _derivedSourceIndex.putIfAbsent(s, () => <String>{}).add(name);
    }
    // Subscribe each source so push frames flow even if no widget is
    // currently watching the source itself.
    unawaited(_ensurePushSubscribed(sources));
    // Compute once now so consumers see a value before the first
    // source-change push.
    _recomputeDerived(name);
    return DerivedHandle(
      name: name,
      onDispose: () {
        _derivedCompute.remove(name);
        final srcs = _derivedSources.remove(name) ?? const [];
        for (final s in srcs) {
          _derivedSourceIndex[s]?.remove(name);
          if (_derivedSourceIndex[s]?.isEmpty ?? false) {
            _derivedSourceIndex.remove(s);
          }
        }
        _values.remove(name);
        _lastUpdateAt.remove(name);
        // Fire null so any active watcher sees the derived going away.
        _watchers[name]?.add(null);
      },
    );
  }

  /// Recompute one derived feature, updating the cache + waking
  /// watchers if the result changed.
  void _recomputeDerived(String name) {
    final compute = _derivedCompute[name];
    final sources = _derivedSources[name];
    if (compute == null || sources == null) return;
    final inputs = <String, int?>{for (final s in sources) s: _values[s]};
    final result = compute(inputs);
    final prior = _values[name];
    if (result == prior) return;
    if (result == null) {
      _values.remove(name);
    } else {
      _values[name] = result;
    }
    _lastUpdateAt[name] = DateTime.now();
    _watchers[name]?.add(result);
    if (_changes.hasListener) _changes.add(name);
  }

  /// Walk every derived feature whose source set includes [source]
  /// and recompute it. Called from the push-stream listener.
  void _recomputeDerivedFor(String source) {
    final affected = _derivedSourceIndex[source];
    if (affected == null) return;
    for (final name in affected) {
      _recomputeDerived(name);
    }
  }

  @override
  Future<void> verifyActionContract({required Set<String> expected}) async {
    if (_transport is! CarBridge) return;
    return action_contract.verifyActionContract(_transport, expected: expected);
  }

  // ── Internals ────────────────────────────────────────────────────

  Future<void> _ensureSeeded() async {
    if (_seeded) return;
    final inFlight = _seedingFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final f = _seed();
    _seedingFuture = f;
    await f;
    _seedingFuture = null;
  }

  /// Boot warmup — populates the SDK's hot cache so any reader (the
  /// dashboard, a mini-app calling `car.read`, the gate-probe screen)
  /// sees real values on the first frame without each having to wait
  /// for a push frame.
  ///
  /// Two phases:
  ///
  ///   1. **Sync fast-path** — batched daemon fetch of [bydBootWarmSet]
  ///      (~22 dashboard names). One round-trip, ~30 ms on Leopard 8.
  ///      Dashboard tiles paint with real values on their first frame.
  ///
  ///   2. **Async background-fill** — push-subscribe the *full* catalog
  ///      (`bydStatusLabelToCatalog.values`, ~1035 names). On the
  ///      first subscribe per name the host emits a synchronisation
  ///      frame carrying the current value; that frame lands in
  ///      [_attachPushStream] and writes into [_values]. So just doing
  ///      the subscriptions populates the cache. By the time a mini-app
  ///      has finished its handshake + first `car.read` (typically
  ///      300-500 ms post-boot), most signals are cached and the read
  ///      returns real numbers instead of nulls.
  ///
  ///      Without this phase, mini-apps that read signals outside the
  ///      warm set show `—` until either (a) the user opens the
  ///      gate-probe screen, which fires the same blanket subscribe,
  ///      or (b) the host happens to push a change frame for that
  ///      specific signal. Slow-changing signals like
  ///      `battery_capacity` may not push for minutes.
  ///
  ///      Cost: ~1000 host subscribe calls. Batched 64 at a time per
  ///      v2-bridge limit; ~5-10 s wall clock total. Fire-and-forget —
  ///      boot completes without awaiting this.
  Future<void> _seed() async {
    // ── Phase 1: sync fast-path for the dashboard. ──────────────────
    await _reseedWarmSet();
    unawaited(_ensurePushSubscribed(bydBootWarmSet));
    _seeded = true;

    // ── Phase 2: async background-fill for mini-apps. ───────────────
    // Subscribes to every other catalog name so mini-apps that
    // `car.read` signals outside the dashboard warm set hit the cache
    // on first call instead of seeing nulls.
    unawaited(_backgroundFillFullCatalog());

    // ── Phase 3: periodic warm-set re-seed. ─────────────────────────
    // The push pipeline doesn't deliver every value: BYD's daemon
    // only pushes deltas, and some signals (AC setpoint, fan level,
    // trunk state) can sit at the same value for hours — they never
    // fire a "value changed" frame, so the SDK's hot cache for those
    // names never gets populated past whatever the boot seed grabbed.
    //
    // If the daemon happens to be slow at boot (TCP not yet bound,
    // adb still authorising), the seed's ``getValuesByName`` returns
    // empty or fails entirely. Without a recovery path the warm set
    // stays null for the whole session, [CarGate] reports null for
    // those fields, [StatusPublisher] skips them in its publish, the
    // backend's ``car_status`` row carries forward whatever stale
    // values it had, and the miniapp renders fallbacks ("22" for the
    // temp slider, "–" for the fan stepper). Reported by a user on
    // 2026-05-15.
    //
    // A 60 s periodic re-read of the warm set is a cheap belt-and-
    // braces: ~22 names × ~5 ms per daemon getInt = ~110 ms of work
    // per minute. Recovers from a missed boot-seed AND keeps the
    // cache fresh against any silent BYD framework state change.
    _warmReseedTimer?.cancel();
    _warmReseedTimer = Timer.periodic(_warmReseedInterval, (_) {
      unawaited(_reseedWarmSet());
    });
  }

  /// Read [bydBootWarmSet] from the daemon and overwrite the matching
  /// entries in [_values]. Distinct from the original seed in two
  /// ways:
  ///   * **Overwrite, not ``putIfAbsent``** — a stale cached value
  ///     would otherwise pin the hot cache forever. The daemon read
  ///     is fresher by definition; let it win.
  ///   * **Safe to call repeatedly** — used both at boot (Phase 1
  ///     fast-path) and from the periodic timer (Phase 3).
  /// Errors are absorbed; the next tick retries. ``_changes`` fires
  /// only when at least one value actually mutated, so consumers
  /// don't redraw on a no-op pass.
  Future<void> _reseedWarmSet() async {
    final Map<String, int> fresh;
    try {
      fresh = await _transport.getValuesByName(bydBootWarmSet);
    } catch (_) {
      // Daemon offline or transport throttled — drop the pass; the
      // next periodic tick will retry.
      return;
    }
    if (fresh.isEmpty) return;
    final now = DateTime.now();
    var changed = false;
    fresh.forEach((k, v) {
      if (_values[k] != v) {
        _values[k] = v;
        changed = true;
      }
      _lastUpdateAt[k] = now;
    });
    if (changed && _changes.hasListener) _changes.add('');
    if (changed) _schedulePersist();
  }

  /// 60 s between re-seeds. Tight enough that a missed push event
  /// surfaces within a status-publish window (the publisher's
  /// keep-alive is 30 s), loose enough to keep the daemon load at
  /// ~110 ms/min per car.
  static const Duration _warmReseedInterval = Duration(seconds: 60);
  Timer? _warmReseedTimer;

  /// Push-subscribe every catalog name outside the dashboard warm
  /// set. Each subscription causes the host to emit a synchronisation
  /// frame with the current value, which lands in [_attachPushStream]
  /// and populates [_values]. Idempotent — names already subscribed
  /// are no-ops via [_ensurePushSubscribed]'s `_subscribedPushNames`
  /// guard.
  ///
  /// Errors are absorbed: a single batched-subscribe failure shouldn't
  /// take down boot. Names that fail to subscribe stay in the
  /// `_subscribedPushNames` set (the per-call exception is caught in
  /// [_ensurePushSubscribed]) so we don't retry-thrash the host.
  Future<void> _backgroundFillFullCatalog() async {
    final allNames = bydStatusLabelToCatalog.values.toSet();
    allNames.removeAll(bydBootWarmSet);
    if (allNames.isEmpty) return;
    try {
      await _ensurePushSubscribed(allNames);
    } catch (_) {
      // Already swallowed inside _ensurePushSubscribed for the inner
      // transport call; nothing additional to do here.
    }
  }

  /// Ask the host to push-subscribe each name in [names] that we
  /// haven't already subscribed. Idempotent — names already in
  /// [_subscribedPushNames] are skipped.
  Future<void> _ensurePushSubscribed(Iterable<String> names) async {
    final fresh = names.where(_subscribedPushNames.add).toList(growable: false);
    if (fresh.isEmpty) return;
    try {
      await _transport.subscribePushByNames(fresh);
    } catch (_) {
      // Subscribe failed — no live updates for these names this
      // session. Periodic re-seed (future work) or a hot-restart
      // recovers. Don't roll back _subscribedPushNames; we don't
      // want to thrash the host with retries on every watch().
    }
  }

  void _attachPushStream() {
    const channel = EventChannel('ilink/car/registry');
    _pushSub = channel.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        final name = event['name'];
        final value = event['value'];
        if (name is! String || value is! int) return;
        _values[name] = value;
        _lastUpdateAt[name] = DateTime.now();
        _watchers[name]?.add(value);
        if (_changes.hasListener) _changes.add(name);
        _schedulePersist();
        // Fan out to any derived feature that depends on this source.
        _recomputeDerivedFor(name);
        // A fresh push frame == daemon definitely up.
        _setConnectionState(DaemonState.connected);
      },
      onError: (_) {
        /* graceful: values stay at last-known */
      },
    );
    _startHealthPoll();
  }

  Future<void> dispose() async {
    for (final h in _commonDeriveHandles) {
      h.dispose();
    }
    _healthTimer?.cancel();
    _healthTimer = null;
    _persistDebounce?.cancel();
    _persistDebounce = null;
    // Final flush on dispose so we don't lose the last 500 ms of
    // changes that the debouncer was sitting on.
    await _persistDiskLkv();
    await _connectionState.close();
    _derivedCompute.clear();
    _derivedSources.clear();
    _derivedSourceIndex.clear();
    await _pushSub?.cancel();
    for (final c in _watchers.values) {
      if (!c.isClosed) await c.close();
    }
    _watchers.clear();
    if (!_changes.isClosed) await _changes.close();
  }

  // ── Test-only hooks ─────────────────────────────────────────────
  // Tests reach into BydClient via these helpers instead of touching
  // private state. Marked @visibleForTesting so an unintended app
  // call surfaces as an analyzer warning.

  @visibleForTesting
  void setForTest(String name, int value) {
    _values[name] = value;
    _lastUpdateAt[name] = DateTime.now();
  }

  @visibleForTesting
  void handlePushForTest(String name, int value) {
    _values[name] = value;
    _lastUpdateAt[name] = DateTime.now();
    _watchers[name]?.add(value);
    _recomputeDerivedFor(name);
  }

  // ── Disk LKV — survives app restarts ────────────────────────────
  //
  // Cold restarts used to paint every dashboard tile as `--` for the
  // ~30 ms boot fetch window. Writing the hot cache to disk on every
  // change (debounced 500 ms) lets the next process load instantly
  // showing yesterday's last-known value, then over-write with fresh
  // pushes as they arrive. Stale-but-present beats blank-and-loading.

  Future<File>? _lkvFileFuture;
  Future<File> _lkvFile() {
    return _lkvFileFuture ??= _resolveLkvFile();
  }

  Future<File> _resolveLkvFile() async {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/byd_client_lkv.json');
    if (!await f.parent.exists()) await f.parent.create(recursive: true);
    return f;
  }

  Future<void> _loadDiskLkv() async {
    try {
      final f = await _lkvFile();
      if (!await f.exists()) return;
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final values = json['values'] as Map<String, dynamic>?;
      final ages = json['ageMs'] as Map<String, dynamic>?;
      if (values == null) return;
      final now = DateTime.now();
      values.forEach((k, v) {
        if (v is int) {
          _values.putIfAbsent(k, () => v);
          // Reconstruct lastUpdateAt from the stored age delta. Loaded
          // values look stale (their freshness ≈ session-old) until a
          // live push refreshes — this is the desired UX (tiles render
          // a stale chip post-restart until a fresh frame arrives).
          final ageMs = ages?[k];
          if (ageMs is int) {
            _lastUpdateAt[k] = now.subtract(Duration(milliseconds: ageMs));
          }
        }
      });
      if (_changes.hasListener) _changes.add('');
    } catch (_) {
      // Corrupt or missing — start fresh; next persist overwrites.
    }
  }

  Timer? _persistDebounce;
  void _schedulePersist() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_persistDiskLkv());
    });
  }

  Future<void> _persistDiskLkv() async {
    try {
      final f = await _lkvFile();
      final now = DateTime.now();
      final ageMs = <String, int>{};
      _lastUpdateAt.forEach((k, t) {
        ageMs[k] = now.difference(t).inMilliseconds;
      });
      final payload = jsonEncode({
        'values': _values,
        'ageMs': ageMs,
        'savedAt': now.toIso8601String(),
      });
      await f.writeAsString(payload, flush: true);
    } catch (_) {
      // Disk full / restricted — non-fatal. Next change re-tries.
    }
  }
}

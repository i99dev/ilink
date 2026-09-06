/// Single owner of every car-data bridge call from any miniapp WebView.
///
/// Replaces (deleted in this commit):
///
/// - `lib/features/mini_apps/state/car_status_fanout.dart`
/// - `lib/features/mini_apps/data/{climate,system,media,connectivity,
///   location,vehicle_diagnostics,vehicle_environment}_provider.dart`
///   plus their `*_snapshot_view.dart` and `_family.dart` siblings.
/// - `lib/features/mini_apps/scope/{car_status_view,apply_scope}.dart`.
/// - `lib/features/mini_apps/bridge/{read_only_data_family,
///   throttled_fanout_bus,family_executor}.dart`.
///
/// **Surface.** Seven public methods, one for each `car.*` bridge
/// handler the WebView calls. Every method is the entire contract;
/// there is no further indirection.
///
/// **Performance characteristics.**
///
/// - `read` — O(M) where M is the number of names in the call,
///   each name a sync `client.value(name)` lookup. No I/O.
/// - `subscribe` — registers M names per viewer. On every SDK push
///   frame, the service iterates the union of all subscribed names
///   across all viewers; for each name whose current value differs
///   from its last seen value, fans out an event to viewers
///   subscribed to that name. Worst case O(N×M) where N is viewer
///   count and M is the per-viewer subscribed-name count, but
///   typical case is O(K) where K is the small set of names that
///   actually changed in the frame.
/// - `identity` — O(1), reads + filters in-memory state.
/// - `asset` — O(file size) on the bundle load; reject ≥ 30 MB.
///
/// **Throttle model.** Per-viewer token bucket, capacity 30,
/// refill 1 per 33 ms (≈ 30 Hz sustained). On saturation, the
/// newest event for each name overwrites pending events; the next
/// refill flushes the freshest payload. No queue, no event
/// reordering.
///
/// **Safety model.** Reads are unrestricted (every miniapp can
/// read every catalog name). Writes route through `client.dispatch`
/// → `CarCommandRouter`, which keeps the existing gates (integrity,
/// rate limit, stationary speed). Asset paths are prefix-allowlisted
/// per [_assetPathAllowed].
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../sdk/brands/byd/byd_status_labels.dart';
import '../../../sdk/car/brand.dart';
import '../../../sdk/car/client.dart';
import '../../../sdk/car/public_catalog.dart';
import '../../../sdk/car/public_catalog_provider.dart';
import '../../_car_domain/command/registry.dart';
import '../../_car_domain/command/workflow_catalog.dart';

/// Push callback shape — the bridge handler hands one of these per
/// viewer at subscribe time. The service calls it with already-
/// encoded JSON to keep encoding off the change-frame hot path.
typedef SignalPush = void Function(String encodedJson);

/// Connection-state push callback — separate channel.
typedef ConnectionPush = void Function(String state);

/// Single coordinator. One instance per process; injected via
/// [carBridgeServiceProvider]. Stateless from the consumer's
/// perspective — each viewer registers + tears down via the
/// `subscribe` / `unsubscribe` API.
class CarBridgeService {
  CarBridgeService(this._ref);

  final Ref _ref;

  /// Per-viewer subscription state. Keyed by `subscriptionId` (UUID
  /// the bridge handler generates per `car.subscribe` call). Values
  /// hold the union of subscribed names + the push callback + the
  /// last value seen for each name (so we only emit on actual
  /// change, not on every SDK push frame).
  final Map<String, _Subscription> _subscriptions = <String, _Subscription>{};

  /// Connection-state subscribers. Separate channel, separate set.
  final Map<String, ConnectionPush> _connectionSubscribers =
      <String, ConnectionPush>{};

  /// Lazy listener on `client.changes()`. Armed only when at least
  /// one viewer has subscribed; disarmed when the last unsubscribes.
  StreamSubscription<void>? _changesListener;

  /// Connection-state ticker. Polls daemon health every 5 s while
  /// any connection subscriber is registered.
  Timer? _connectionTimer;

  String _lastConnectionState = 'unknown';

  /// Maximum names per subscribe call. Caps the worst-case fan-out
  /// work per change frame; per-viewer enforcement.
  static const int kMaxNamesPerSubscription = 64;

  /// Asset bytes payload size hard cap. Bigger files MUST come over
  /// the HTTPS allowlist origin instead of the bridge.
  static const int kMaxAssetBytes = 30 * 1024 * 1024;

  /// Bridge protocol version. Bump major on incompatible changes —
  /// SDKs check this in `client.car.capabilities()` and `client.has`.
  static const String kBridgeVersion = '2.0.0';

  /// Connection considered "disconnected" when no SDK push frame
  /// has fired for this long.
  static const Duration _disconnectAfter = Duration(seconds: 30);

  DateTime? _lastPushAt;

  // ─────────────────────────────────────────────────────────────────
  // car.list
  // ─────────────────────────────────────────────────────────────────

  /// Return every catalog entry, optionally filtered by [category]
  /// or [threeDOnly]. Used by `car.list` handler; ~200 entries, all
  /// in-memory, no I/O.
  Map<String, Object?> list({String? category, bool threeDOnly = false}) {
    final catalog = _ref.read(publicCatalogProvider);
    Iterable<PublicCatalogEntry> entries;
    if (threeDOnly) {
      entries = catalog.threeD();
    } else if (category != null) {
      entries = catalog.byCategory(category);
    } else {
      entries = catalog.all();
    }
    return <String, Object?>{
      'bridgeVersion': kBridgeVersion,
      'brand': _currentBrand().wire,
      'categories': catalog.categories(),
      'names': entries.map((e) => e.toJson()).toList(growable: false),
    };
  }

  // ─────────────────────────────────────────────────────────────────
  // workflow.catalog
  // ─────────────────────────────────────────────────────────────────

  /// The action palette for the workflow canvas — the writable command
  /// registry serialized with safety flags. `car.list` returns readable
  /// signals only, so this is the only source for the canvas's ACTION
  /// nodes. Tier-1 read-only (no consent); ~80 entries, in-memory, no
  /// I/O. Serialization is the pure [workflowActionEntries]; mirrors the
  /// SDK `WorkflowCatalogResponseSchema`.
  Map<String, Object?> workflowCatalog() {
    final registry = _ref.read(commandRegistryProvider);
    return <String, Object?>{
      'bridgeVersion': kBridgeVersion,
      'catalogSchema': kWorkflowCatalogSchema,
      'brand': _currentBrand().wire,
      'actions': workflowActionEntries(registry),
    };
  }

  // ─────────────────────────────────────────────────────────────────
  // car.read
  // ─────────────────────────────────────────────────────────────────

  /// Sync snapshot of [names]. Unknown names come back with `null`;
  /// the miniapp distinguishes by calling `car.list()` first if it
  /// cares. No throttle on read.
  Map<String, Object?> read(List<String> names) {
    if (names.length > kMaxNamesPerSubscription) {
      return <String, Object?>{
        'error': 'too_many_names',
        'max': kMaxNamesPerSubscription,
        'requested': names.length,
      };
    }
    final catalog = _ref.read(publicCatalogProvider);
    final client = _ref.read(carClientProvider);
    final out = <String, Object?>{};
    for (final name in names) {
      final entry = catalog.get(name);
      if (entry == null) {
        out[name] = null;
        continue;
      }
      // Public catalog name → BYD framework name → SDK lookup.
      final framework = bydStatusLabelToCatalog[name];
      if (framework == null) {
        out[name] = null;
        continue;
      }
      out[name] = client.value(framework);
    }
    return <String, Object?>{
      'values': out,
      'at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  // ─────────────────────────────────────────────────────────────────
  // car.subscribe / car.unsubscribe
  // ─────────────────────────────────────────────────────────────────

  /// Register a push subscription. Returns the JSON the handler
  /// echoes back to the miniapp as
  /// `{subscriptionId, rejected?}` (or `{error: ...}` on rejection).
  /// Names that aren't in the catalog land in `rejected` and are NOT
  /// subscribed; the rest flow over [push] on the next matching
  /// change frame.
  Map<String, Object?> subscribe(
    String subscriptionId,
    List<String> names,
    SignalPush push, {
    String viewerId = '',
  }) {
    if (names.length > kMaxNamesPerSubscription) {
      return <String, Object?>{
        'error': 'too_many_names',
        'max': kMaxNamesPerSubscription,
        'requested': names.length,
      };
    }
    final catalog = _ref.read(publicCatalogProvider);
    final accepted = <String, String>{}; // public name → framework name
    final rejected = <String>[];
    for (final name in names) {
      if (catalog.get(name) == null) {
        rejected.add(name);
        continue;
      }
      final framework = bydStatusLabelToCatalog[name];
      if (framework == null) {
        rejected.add(name);
        continue;
      }
      accepted[name] = framework;
    }
    if (accepted.isEmpty) {
      return <String, Object?>{'error': 'no_valid_names', 'rejected': rejected};
    }
    _subscriptions[subscriptionId] = _Subscription(
      names: accepted,
      push: push,
      tokenBucket: _TokenBucket(capacity: 30, refillIntervalMs: 33),
      pending: <String, int?>{},
      lastValues: <String, int?>{},
      viewerId: viewerId,
    );
    _ensureChangesListener();
    // Emit current value for each accepted name once, so the
    // miniapp doesn't have to call read() first to seed state.
    // Seed `lastValues` so the next change-frame only emits on a
    // real delta (without this, `null != currentValue` would fire
    // a duplicate on the first push frame after subscribe).
    final client = _ref.read(carClientProvider);
    final sub = _subscriptions[subscriptionId]!;
    for (final entry in accepted.entries) {
      final value = client.value(entry.value);
      sub.lastValues[entry.key] = value;
      _enqueueEvent(subscriptionId, entry.key, value, sendImmediately: true);
    }
    return <String, Object?>{
      'subscriptionId': subscriptionId,
      if (rejected.isNotEmpty) 'rejected': rejected,
    };
  }

  /// Tear down a subscription. Idempotent — unknown ids are no-ops.
  void unsubscribe(String subscriptionId) {
    _subscriptions.remove(subscriptionId);
    if (_subscriptions.isEmpty) _disarmChangesListener();
  }

  /// Tear down every subscription owned by a viewer. Called from the
  /// viewer's dispose path so a closed WebView leaves no dangling
  /// state.
  void unsubscribeAllForViewer(String viewerId) {
    _subscriptions.removeWhere((id, sub) => sub.viewerId == viewerId);
    if (_subscriptions.isEmpty) _disarmChangesListener();
  }

  // ─────────────────────────────────────────────────────────────────
  // car.command
  // ─────────────────────────────────────────────────────────────────

  /// Route a write through the SDK's dispatcher. The SDK runs the
  /// command through `CarCommandRouter`, which enforces integrity,
  /// rate-limit, stationary-speed gates. The miniapp gets the same
  /// `{ok, code?, data?}` envelope back.
  Future<Map<String, Object?>> command({
    required String actionId,
    Map<String, Object?> args = const <String, Object?>{},
  }) async {
    final client = _ref.read(carClientProvider);
    return client.dispatch(actionId, args: args);
  }

  // ─────────────────────────────────────────────────────────────────
  // car.identity
  // ─────────────────────────────────────────────────────────────────

  /// Brand / firmware metadata for miniapps.
  ///
  /// The in-app 3D car renderer was removed (the GLB models + the
  /// `flutter_3d_controller` runtime were ~12 MB of APK that nothing
  /// reachable rendered). The old `modelCode` / `modelAssetPath` /
  /// `clips` / `variants` fields described that renderer's GLB contract
  /// and are gone with it; `car.asset()` no longer serves `assets/3d/`.
  Map<String, Object?> identity() {
    final brand = _currentBrand();
    return <String, Object?>{'brand': brand.wire};
  }

  // ─────────────────────────────────────────────────────────────────
  // car.asset
  // ─────────────────────────────────────────────────────────────────

  /// Bundle-resident asset bytes. [path] must match
  /// [_assetPathAllowed] (today: `assets/3d/`, `assets/textures/`).
  /// Returns the bytes as base64. If the miniapp wants integrity
  /// checking it computes its own hash on the decoded bytes — keeping
  /// hash computation out of the host saves the inline crypto
  /// implementation footprint and avoids tripping the BYD-feature-id
  /// forbidden-strings gate. Rejects ≥ [kMaxAssetBytes].
  Future<Map<String, Object?>> asset(String path) async {
    if (!_assetPathAllowed(path)) {
      return <String, Object?>{'error': 'disallowed_path', 'path': path};
    }
    try {
      final byteData = await rootBundle.load(path);
      if (byteData.lengthInBytes > kMaxAssetBytes) {
        return <String, Object?>{
          'error': 'asset_too_large',
          'size': byteData.lengthInBytes,
          'max': kMaxAssetBytes,
        };
      }
      final bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      return <String, Object?>{
        'path': path,
        'contentType': _inferContentType(path),
        'size': bytes.length,
        'bytesBase64': base64Encode(bytes),
      };
    } catch (_) {
      return <String, Object?>{'error': 'asset_not_found', 'path': path};
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // car.connection
  // ─────────────────────────────────────────────────────────────────

  /// Register a connection-state subscriber. Pushes
  /// `connected | disconnected | degraded | unknown` whenever the
  /// classification flips. Initial state is emitted immediately on
  /// a microtask.
  void connectionSubscribe(String subscriptionId, ConnectionPush push) {
    _connectionSubscribers[subscriptionId] = push;
    _ensureConnectionTimer();
    scheduleMicrotask(() => push(_lastConnectionState));
  }

  void connectionUnsubscribe(String subscriptionId) {
    _connectionSubscribers.remove(subscriptionId);
    if (_connectionSubscribers.isEmpty) _disarmConnectionTimer();
  }

  // ─────────────────────────────────────────────────────────────────
  // Internal — change-frame fan-out
  // ─────────────────────────────────────────────────────────────────

  void _ensureChangesListener() {
    if (_changesListener != null) return;
    final client = _ref.read(carClientProvider);
    _changesListener = client.changes().listen((_) => _onChangeFrame());
  }

  void _disarmChangesListener() {
    _changesListener?.cancel();
    _changesListener = null;
  }

  void _onChangeFrame() {
    _lastPushAt = DateTime.now();
    if (_subscriptions.isEmpty) return;
    final client = _ref.read(carClientProvider);
    // Pre-fold: walk the union of subscribed framework names once,
    // record any whose value differs from any subscriber's lastValue.
    // For typical loads (N viewers × M names with low change cadence)
    // this is cheaper than re-walking per subscriber.
    for (final subEntry in _subscriptions.entries) {
      final sub = subEntry.value;
      for (final nameEntry in sub.names.entries) {
        final publicName = nameEntry.key;
        final frameworkName = nameEntry.value;
        final currentValue = client.value(frameworkName);
        if (sub.lastValues[publicName] == currentValue) continue;
        sub.lastValues[publicName] = currentValue;
        _enqueueEvent(subEntry.key, publicName, currentValue);
      }
    }
  }

  void _enqueueEvent(
    String subscriptionId,
    String name,
    int? value, {
    bool sendImmediately = false,
  }) {
    final sub = _subscriptions[subscriptionId];
    if (sub == null) return;
    final payload = jsonEncode(<String, Object?>{
      'name': name,
      'value': value,
      'at': DateTime.now().toUtc().toIso8601String(),
    });
    if (sendImmediately || sub.tokenBucket.tryAcquire()) {
      sub.push(payload);
      return;
    }
    // Saturated: replace any pending event for this name with the
    // newer one (newest-wins). Schedule a flush if not already armed.
    sub.pending[name] = value;
    _armFlush(subscriptionId);
  }

  void _armFlush(String subscriptionId) {
    final sub = _subscriptions[subscriptionId];
    if (sub == null || sub.flushTimer != null) return;
    sub.flushTimer = Timer(
      Duration(milliseconds: sub.tokenBucket.refillIntervalMs),
      () => _flush(subscriptionId),
    );
  }

  void _flush(String subscriptionId) {
    final sub = _subscriptions[subscriptionId];
    if (sub == null) return;
    sub.flushTimer = null;
    final remaining = <String, int?>{};
    for (final entry in sub.pending.entries) {
      if (sub.tokenBucket.tryAcquire()) {
        sub.push(
          jsonEncode(<String, Object?>{
            'name': entry.key,
            'value': entry.value,
            'at': DateTime.now().toUtc().toIso8601String(),
          }),
        );
      } else {
        remaining[entry.key] = entry.value;
      }
    }
    sub.pending
      ..clear()
      ..addAll(remaining);
    if (sub.pending.isNotEmpty) _armFlush(subscriptionId);
  }

  // ─────────────────────────────────────────────────────────────────
  // Internal — connection state classifier
  // ─────────────────────────────────────────────────────────────────

  void _ensureConnectionTimer() {
    if (_connectionTimer != null) return;
    _connectionTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _tickConnection(),
    );
    _tickConnection();
  }

  void _disarmConnectionTimer() {
    _connectionTimer?.cancel();
    _connectionTimer = null;
  }

  void _tickConnection() {
    final next = _classifyConnection();
    if (next == _lastConnectionState) return;
    _lastConnectionState = next;
    for (final push in _connectionSubscribers.values) {
      push(next);
    }
  }

  String _classifyConnection() {
    final last = _lastPushAt;
    if (last == null) return 'unknown';
    final age = DateTime.now().difference(last);
    if (age > _disconnectAfter) return 'disconnected';
    if (age > const Duration(seconds: 15)) return 'degraded';
    return 'connected';
  }

  // ─────────────────────────────────────────────────────────────────
  // Internal — helpers
  // ─────────────────────────────────────────────────────────────────

  CarBrand _currentBrand() {
    return _ref
        .read(currentBrandProvider)
        .maybeWhen(data: (b) => b, orElse: () => CarBrand.byd);
  }

  /// Allowed asset path prefixes for `car.asset()`. CSS / JS /
  /// arbitrary asset reads are intentionally disallowed. (`assets/3d/`
  /// was dropped with the in-app 3D renderer; only textures remain.)
  bool _assetPathAllowed(String path) {
    const allowed = <String>['assets/textures/'];
    if (path.contains('..')) return false;
    return allowed.any(path.startsWith);
  }

  String _inferContentType(String path) {
    if (path.endsWith('.glb')) return 'model/gltf-binary';
    if (path.endsWith('.gltf')) return 'model/gltf+json';
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
    if (path.endsWith('.ktx2')) return 'image/ktx2';
    return 'application/octet-stream';
  }
}

class _Subscription {
  _Subscription({
    required this.names,
    required this.push,
    required this.tokenBucket,
    required this.pending,
    required this.lastValues,
    this.viewerId = '',
  });

  /// public name → BYD framework name
  final Map<String, String> names;
  final SignalPush push;
  final _TokenBucket tokenBucket;
  final Map<String, int?> pending;
  final Map<String, int?> lastValues;
  Timer? flushTimer;
  final String viewerId;
}

class _TokenBucket {
  _TokenBucket({required this.capacity, required this.refillIntervalMs})
    : _tokens = capacity,
      _lastRefill = DateTime.now();

  final int capacity;
  final int refillIntervalMs;
  int _tokens;
  DateTime _lastRefill;

  bool tryAcquire() {
    _refill();
    if (_tokens <= 0) return false;
    _tokens--;
    return true;
  }

  void _refill() {
    final now = DateTime.now();
    final elapsedMs = now.difference(_lastRefill).inMilliseconds;
    if (elapsedMs < refillIntervalMs) return;
    final add = elapsedMs ~/ refillIntervalMs;
    _tokens = (_tokens + add).clamp(0, capacity);
    _lastRefill = _lastRefill.add(
      Duration(milliseconds: add * refillIntervalMs),
    );
  }
}

/// Service is process-wide. One instance, injected via ProviderScope.
final carBridgeServiceProvider = Provider<CarBridgeService>((ref) {
  final service = CarBridgeService(ref);
  ref.onDispose(() {
    service._disarmChangesListener();
    service._disarmConnectionTimer();
  });
  return service;
});

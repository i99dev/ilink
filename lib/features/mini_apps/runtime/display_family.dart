/// `display` family — display enumeration + hot-plug subscription
/// for native-capability mini-apps. Tier-1 (read-only); no consent /
/// cap gate beyond the permission lookup.
///
/// Handlers:
///   * `display.list` — returns the current display set as JSON.
///   * `display.subscribe` — registers a listener for hot-plug events
///     (added / removed / changed). Returns `{id}` the caller passes
///     to `unsubscribe`.
///   * `display.unsubscribe` — drops the listener.
///
/// Subscription model is "one EventChannel listener per family
/// instance, fan-out to N pushers." That mirrors `CarStatusFanout`
/// but simpler — every push is a string nanoseconds away from
/// `evaluateJavascript`, with no shared state to project.
///
/// Pure-Dart class — no platform imports. The `*NativeBridge`
/// abstraction is the only seam to native code.
library;

import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import '../../../sdk/brands/byd/identity/byd_model_detector.dart';
import '../../../platform/observability/observability.dart';
import '../../admin_mini_apps/domain/admin_op.dart'
    show ParamRule, RegexParamRule;
import '../bridge/family_event_pusher.dart';
import '../bridge/mini_app_family.dart';
import 'display_native_bridge.dart';
import 'display_snapshot.dart';

class DisplayFamily extends MiniAppFamily {
  DisplayFamily({DisplayNativeBridge? bridge})
    : _bridge = bridge ?? PlatformDisplayNativeBridge() {
    _hotPlug = _DisplayHotPlugBus(_bridge);
  }

  final DisplayNativeBridge _bridge;
  late final _DisplayHotPlugBus _hotPlug;

  @override
  String get familyId => 'display';

  @override
  Set<String> get permissionIds => const {'display.read'};

  @override
  bool get secondaryAllowed => true;

  @override
  late final Map<String, FamilyHandler> handlers = <String, FamilyHandler>{
    'list': _ListHandler(_bridge),
    'subscribe': _SubscribeHandler(_hotPlug),
    'unsubscribe': _UnsubscribeHandler(_hotPlug),
  };

  @override
  Future<void> dispose() async {
    await _hotPlug.dispose();
  }
}

class _ListHandler implements FamilyHandler {
  _ListHandler(this._bridge);
  final DisplayNativeBridge _bridge;

  @override
  Map<String, ParamRule> get paramSchema => const {};
  @override
  bool get requiresStepUp => false;
  @override
  HandlerCadence get cadence => HandlerCadence.standard;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    // D2 cold-boot ordering: model detection MUST resolve BEFORE
    // `display.list` so the native side resolves the snapshot
    // against the detected trim's profile, not the pre-detection
    // Generic fallback. `detect()`'s first resolve also pushes the
    // id chain that sets the Kotlin active profile, so sequencing
    // list() after it closes the cold-boot race. `detect()` caches
    // forever → this only adds latency on the very first mini-app
    // cold-start.
    //
    // ModelDetector is best-effort — on non-Android platforms (web /
    // dev macOS) the detector returns ModelId.unknown without
    // throwing, so the field is always present even in the dev
    // runner. capabilityBits is wrapped to never throw — empty caps
    // is the safe default the catalog filter understands. It shares
    // no state with the list/detect pair, so it still pipelines.
    final capsFuture = _bridge.capabilityBits().catchError(
      (_) => const VehicleCapabilityResult(bits: 0, capabilities: []),
    );
    final model = await ModelDetector.detect();
    final displays = await _bridge.list();
    final capsResult = await capsFuture;
    // Phase 1 telemetry: emit one `display.classified` Sentry log per
    // unique (name, w, h) tuple per 24h. Dedup state lives in
    // SharedPreferences so repeat list() calls in the same drive
    // don't spam. Fired AFTER the result is built so a slow Sentry
    // ingest never blocks display.list latency — fire-and-forget,
    // exceptions swallowed inside Observability.
    final locale = PlatformDispatcher.instance.locale.toLanguageTag();
    for (final d in displays) {
      // ignore: discarded_futures, unawaited_futures
      Observability.logDisplayClassified(
        name: d.name,
        widthPx: d.width,
        heightPx: d.height,
        displayId: d.id,
        role: d.role,
        source: d.source,
        confidence: d.confidence,
        markerPresent: d.source == 'MARKER',
        dimReason: d.dimReason,
        variantId: model.variant,
        dilinkFamily: model.dilinkFamily,
        locale: locale,
      );
    }
    return <String, Object?>{
      'displays': displays.map((d) => d.toJson()).toList(growable: false),
      'vehicle': <String, Object?>{
        'variantId': model.variant,
        'friendlyName': model.friendlyName,
        'dilinkFamily': model.dilinkFamily,
        // Capability bitmask + readable list. Mini-apps that pre-empt
        // unsupported actions (e.g. show "cluster not supported on
        // this trim" before the user taps) consult these. Bitmask is
        // the fast path; the array is the compatibility path for SDK
        // consumers that don't want to round-trip the bit table.
        // Both are populated atomically — the registry never returns
        // bits without their readable equivalent.
        'capabilityBits': capsResult.bits,
        'capabilities': capsResult.capabilities,
      },
    };
  }
}

class _SubscribeHandler implements FamilyHandler {
  _SubscribeHandler(this._bus);
  final _DisplayHotPlugBus _bus;

  @override
  Map<String, ParamRule> get paramSchema => const {};
  @override
  bool get requiresStepUp => false;
  @override
  HandlerCadence get cadence => HandlerCadence.stream;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final id = _bus.attach(call.eventPusher);
    return <String, Object?>{'id': id};
  }
}

class _UnsubscribeHandler implements FamilyHandler {
  _UnsubscribeHandler(this._bus);
  final _DisplayHotPlugBus _bus;

  @override
  Map<String, ParamRule> get paramSchema => <String, ParamRule>{
    'id': RegexParamRule(pattern: r'^sub_[0-9]+$'),
  };
  @override
  bool get requiresStepUp => false;
  @override
  HandlerCadence get cadence => HandlerCadence.stream;

  @override
  Future<Map<String, Object?>> execute(BridgeCall call) async {
    final id = call.params['id']! as String;
    final dropped = _bus.detach(id);
    return <String, Object?>{'ok': dropped};
  }
}

/// Process-wide bus that turns the EventChannel stream into a
/// fan-out: lazy native attach on first subscriber, idempotent
/// detach, native release on last subscriber. Subscription ids are
/// monotonic strings so the unsubscribe regex can validate them
/// without ambiguity.
///
/// `_pushers` is a list-of-pairs (id, pusher) instead of a Map so
/// fan-out preserves attach order — a mini-app subscribing twice
/// gets two separate callbacks, which matches the SDK side's ref-
/// counting expectations.
class _DisplayHotPlugBus {
  _DisplayHotPlugBus(this._bridge);
  final DisplayNativeBridge _bridge;

  StreamSubscription<DisplayEvent>? _nativeSub;
  final List<({String id, FamilyEventPusher pusher})> _pushers = [];
  int _nextId = 0;

  /// Add a pusher; returns its monotonic subscription id. Lazily
  /// attaches the native EventChannel listener on first add.
  String attach(FamilyEventPusher pusher) {
    final id = 'sub_${_nextId++}';
    _pushers.add((id: id, pusher: pusher));
    _ensureNativeListener();
    return id;
  }

  /// Remove a pusher by id. Returns whether anything was actually
  /// removed (so the SDK side can tell idempotent retries from
  /// stale ids). Detaches native listener when last pusher leaves.
  bool detach(String id) {
    final before = _pushers.length;
    _pushers.removeWhere((e) => e.id == id);
    final dropped = _pushers.length != before;
    if (_pushers.isEmpty) {
      _nativeSub?.cancel();
      _nativeSub = null;
    }
    return dropped;
  }

  /// Test seam: drop everything (used by [DisplayFamily.dispose]).
  Future<void> dispose() async {
    _pushers.clear();
    await _nativeSub?.cancel();
    _nativeSub = null;
  }

  void _ensureNativeListener() {
    if (_nativeSub != null) return;
    _nativeSub = _bridge.events().listen(
      _dispatch,
      onError: (_) {
        // EventChannel surface — a native crash shouldn't take down
        // the family. Drop the listener so the next subscribe will
        // re-attach against a fresh stream.
        _nativeSub?.cancel();
        _nativeSub = null;
      },
    );
  }

  void _dispatch(DisplayEvent event) {
    final payload = event.toJson();
    // Snapshot the pushers list — a pusher that detaches mid-fan-out
    // (e.g. WebView torn down during dispatch) shouldn't crash the
    // iteration.
    final snapshot = List.of(_pushers);
    for (final entry in snapshot) {
      try {
        entry.pusher.pushEvent('display', payload);
      } catch (_) {
        // Pushers are idempotent against post-dispose; swallow.
      }
    }
  }
}

/// A pure-Dart [CarClient] for unit tests.
///
/// Returns sensible defaults — `null` for `value`, an empty stream from
/// `watch` / `changes`, `{}` for bulk reads — so tests that transitively
/// build providers depending on `carClientProvider` can spin up a
/// [ProviderContainer] without booting the real `BydClient` (which
/// touches Android platform channels).
///
/// Every call lands in [calls] as a `(method, args)` record so tests
/// can assert ordering. Zero outward dependencies beyond the SDK's
/// abstract surface — no MethodChannel, no EventChannel, no host I/O.
library;

import 'dart:async';

import 'package:ilink/sdk/car/car_caller.dart';
import 'package:ilink/sdk/car/client.dart';

class FakeCarClient implements CarClient {
  /// Ordered log of every call this fake received. Each entry is a
  /// `(method: <name>, args: <named-args>)` record.
  final List<({String method, Map<String, dynamic> args})> calls = [];

  /// Optional canned hot-cache values keyed by catalog name. Reads
  /// through [value] / [liveFeaturesSync] honor this map; tests that
  /// need a specific feature value seed it here.
  final Map<String, int?> values = <String, int?>{};

  /// Optional canned reply for [dispatch] / [invoke]. Defaults to
  /// `{ok: true}`.
  Map<String, Object?> dispatchReply = const {'ok': true};

  /// Per-name ages returned by [freshness] (null/absent = never seen).
  final Map<String, Duration?> freshnessByName = <String, Duration?>{};

  /// When set, [refreshValue] adopts these into [values] before returning —
  /// simulates a live read landing a new value. Null → returns the existing
  /// [values] entry unchanged.
  Map<String, int?>? refreshValues;

  /// When true, [refreshValue] throws — simulates a daemon-unreachable read.
  bool refreshThrows = false;

  final StreamController<String> _changes =
      StreamController<String>.broadcast();
  final StreamController<DaemonState> _connection =
      StreamController<DaemonState>.broadcast();
  DaemonState _state = DaemonState.disconnected;

  @override
  int? value(String name) {
    calls.add((method: 'value', args: {'name': name}));
    return values[name];
  }

  @override
  Future<int?> refreshValue(String name) async {
    calls.add((method: 'refreshValue', args: {'name': name}));
    if (refreshThrows) throw StateError('refresh failed');
    final next = refreshValues?[name];
    if (next != null) values[name] = next;
    return values[name];
  }

  @override
  Stream<int?> watch(String name) {
    calls.add((method: 'watch', args: {'name': name}));
    return const Stream<int?>.empty();
  }

  @override
  Future<Map<String, int>> liveFeatures() async {
    calls.add((method: 'liveFeatures', args: const {}));
    return <String, int>{};
  }

  @override
  Map<String, int> liveFeaturesSync() {
    calls.add((method: 'liveFeaturesSync', args: const {}));
    return {
      for (final e in values.entries)
        if (e.value != null) e.key: e.value!,
    };
  }

  @override
  Future<Map<String, int>> allCatalogNames() async {
    calls.add((method: 'allCatalogNames', args: const {}));
    return <String, int>{};
  }

  @override
  Future<Map<String, Object?>> dispatch(
    String actionId, {
    Map<String, Object?> args = const {},
    CarCaller? caller,
  }) async {
    calls.add((
      method: 'dispatch',
      args: {'actionId': actionId, 'args': args, 'caller': caller},
    ));
    return Map<String, Object?>.from(dispatchReply);
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
    calls.add((
      method: 'dispatchAndConfirm',
      args: {
        'actionId': actionId,
        'name': name,
        'timeout': timeout,
        'args': args,
        'caller': caller,
      },
    ));
    return DispatchResult(
      result: Map<String, dynamic>.from(dispatchReply),
      confirmed: false,
    );
  }

  @override
  Future<Map<String, Object?>> invoke(
    String actionId, [
    Map<String, Object?> args = const {},
  ]) async {
    calls.add((method: 'invoke', args: {'actionId': actionId, 'args': args}));
    return Map<String, Object?>.from(dispatchReply);
  }

  @override
  Stream<String> changes() => _changes.stream;

  @override
  Duration? freshness(String name) {
    calls.add((method: 'freshness', args: {'name': name}));
    return freshnessByName[name];
  }

  @override
  Future<Map<String, dynamic>> daemonStatus() async {
    calls.add((method: 'daemonStatus', args: const {}));
    return const {'daemon': false, 'adb': false};
  }

  @override
  Future<Map<String, dynamic>> identity({bool localOnly = false}) async {
    calls.add((method: 'identity', args: {'localOnly': localOnly}));
    return const {};
  }

  @override
  Future<List<String>> knownActions() async {
    calls.add((method: 'knownActions', args: const {}));
    return const [];
  }

  @override
  Future<Map<String, dynamic>> registryStats() async {
    calls.add((method: 'registryStats', args: const {}));
    return const {};
  }

  @override
  Future<Map<String, dynamic>> acTransact(
    String service,
    String method, {
    Map<String, dynamic>? args,
  }) async {
    calls.add((
      method: 'acTransact',
      args: {'service': service, 'method': method, 'args': args ?? const {}},
    ));
    return const {};
  }

  @override
  Stream<Map<String, dynamic>> observeFamily(String family) {
    calls.add((method: 'observeFamily', args: {'family': family}));
    return const Stream<Map<String, dynamic>>.empty();
  }

  @override
  Future<Map<String, dynamic>?> readFamily(String family) async {
    calls.add((method: 'readFamily', args: {'family': family}));
    return null;
  }

  @override
  Future<void> verifyActionContract({required Set<String> expected}) async {
    calls.add((method: 'verifyActionContract', args: {'expected': expected}));
  }

  @override
  Stream<DaemonState> connectionState() {
    // Emits current state immediately on listen, like the real impl.
    return _connection.stream
        .transform(
          StreamTransformer<DaemonState, DaemonState>.fromHandlers(
            handleData: (data, sink) => sink.add(data),
          ),
        )
        .asBroadcastStream(
          onListen: (sub) {
            scheduleMicrotask(() => _connection.add(_state));
          },
        );
  }

  @override
  DaemonState get currentConnectionState => _state;

  @override
  DerivedHandle derive({
    required String name,
    required List<String> sources,
    required int? Function(Map<String, int?> sources) compute,
  }) {
    calls.add((method: 'derive', args: {'name': name, 'sources': sources}));
    return DerivedHandle(name: name, onDispose: () {});
  }

  // ── Test helpers ─────────────────────────────────────────────────

  /// Fire a synthetic push tick — drives [changes] subscribers. Pass the
  /// changed catalog [name] to exercise the per-name fast path; the no-arg
  /// form emits '' (a batch/unknown frame).
  void pushChange([String name = '']) => _changes.add(name);

  /// Drive the [connectionState] stream.
  void setConnectionState(DaemonState next) {
    _state = next;
    _connection.add(next);
  }

  /// Drop all stream controllers. Call from `addTearDown` if a test
  /// asserts no-leak behaviour.
  Future<void> dispose() async {
    await _changes.close();
    await _connection.close();
  }
}

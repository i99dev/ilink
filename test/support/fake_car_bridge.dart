import 'package:ilink/sdk/car/_transport/car_bridge.dart';

/// A [CarBridge] that records every call and returns a scripted
/// response. Used by router, controller, state, and compat tests to
/// exercise the pure-Dart code paths without any platform channel.
///
/// Every method records a [BridgeCall] in [calls] so tests can assert
/// call order / counts (e.g. `readStatusCalls == 0` when compat reused
/// the cache). The various `...Response` fields let a test configure
/// what comes back from each method independently.
class FakeCarBridge extends CarBridge {
  FakeCarBridge({
    this.response = const {'ok': true, 'code': 0},
    this.knownActionsResponse = const [],
    this.knownUnitsResponse = const [],
    this.daemonResponse = const {'daemon': true},
    this.identityResponse = const {},
    this.simulateKnownActionsHang = false,
  }) : super(mockCar: true);

  /// Every call made through this fake, in order. Each entry holds the
  /// method name ('runAction' | 'runUnit' | 'acTransact'
  /// | 'knownActions' | 'daemonStatus' | 'carIdentity') and the args
  /// the caller passed.
  final List<BridgeCall> calls = [];

  /// Canned response returned from the action/unit calls. Override per test
  /// for failure cases.
  Map<String, dynamic> response;

  /// Canned list returned from [knownActions]. Defaults empty.
  List<String> knownActionsResponse;

  /// Canned list returned from [knownUnits]. Defaults empty.
  List<String> knownUnitsResponse;

  /// Canned map returned from [daemonStatus]. Default mimics a healthy
  /// daemon; set `{'daemon': false}` to exercise the offline path.
  Map<String, dynamic> daemonResponse;

  /// Canned map returned from [carIdentity]. Empty by default so tests
  /// opt in to identity fields they care about.
  Map<String, dynamic> identityResponse;

  /// When true, [knownActions] hangs for 30 s so tests can exercise
  /// timeout paths without real platform latency.
  bool simulateKnownActionsHang;

  @override
  Future<Map<String, dynamic>> runAction(
    String id, [
    Map<String, dynamic> args = const {},
  ]) async {
    calls.add(BridgeCall('runAction', {'id': id, 'args': args}));
    return Map<String, dynamic>.from(response);
  }

  @override
  Future<Map<String, dynamic>> runUnit(String unit, List<String> args) async {
    calls.add(BridgeCall('runUnit', {'unit': unit, 'args': args}));
    return Map<String, dynamic>.from(response);
  }

  @override
  Future<Map<String, dynamic>> acTransact(
    String service,
    String method, {
    Map<String, dynamic>? args,
  }) async {
    calls.add(
      BridgeCall('acTransact', {
        'service': service,
        'method': method,
        'args': args ?? const {},
      }),
    );
    return Map<String, dynamic>.from(response);
  }

  @override
  Future<List<String>> knownActions() async {
    if (simulateKnownActionsHang) {
      await Future.delayed(const Duration(seconds: 30));
    }
    calls.add(const BridgeCall('knownActions', {}));
    return List.of(knownActionsResponse);
  }

  @override
  Future<List<String>> knownUnits() async {
    calls.add(const BridgeCall('knownUnits', {}));
    return List.of(knownUnitsResponse);
  }

  @override
  Future<Map<String, dynamic>> daemonStatus() async {
    calls.add(const BridgeCall('daemonStatus', {}));
    return Map<String, dynamic>.from(daemonResponse);
  }

  @override
  Future<Map<String, dynamic>> carIdentity() async {
    calls.add(const BridgeCall('carIdentity', {}));
    return Map<String, dynamic>.from(identityResponse);
  }

  /// Convenience: ids that went through [runAction]. Order preserved.
  List<String> get runActionIds =>
      calls.where((c) => c.method == 'runAction').map((c) {
        return c.args['id'] as String;
      }).toList();

  /// Convenience: how many times [readStatus] was hit. Compat probe
  /// tests use this to confirm the bridge was skipped when a fresh
  /// `CarStateController` snapshot was available.
  int get readStatusCalls =>
      calls.where((c) => c.method == 'readStatus').length;
}

class BridgeCall {
  const BridgeCall(this.method, this.args);
  final String method;
  final Map<String, dynamic> args;
}

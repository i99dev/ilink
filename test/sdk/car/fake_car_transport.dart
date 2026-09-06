/// Minimal scriptable [CarTransport] for SDK unit tests. Records every
/// call; canned responses live in mutable fields so a test can override
/// per-method without subclassing.
library;

import 'package:ilink/sdk/car/_transport/car_transport.dart';

class FakeCarTransport implements CarTransport {
  /// (method-name, args) for every call, in order. Tests assert
  /// dispatch ordering / call count via this.
  final List<({String method, Map<String, dynamic> args})> calls = [];

  /// Canned replies — overwrite per test for failure paths.
  Map<String, dynamic> runActionResponse = const {'ok': true, 'code': 0};
  Map<String, int> getValuesResponse = const {};
  Map<String, dynamic> daemonStatusResponse = const {'daemon': true};
  Map<String, dynamic> identityResponse = const {};
  Map<String, dynamic> identityLocalResponse = const {};
  List<String> knownActionsResponse = const [];
  Map<String, dynamic> registryStatsResponse = const {};
  Map<String, dynamic>? readContentProviderResponse;

  @override
  Future<Map<String, dynamic>> runAction(
    String id, [
    Map<String, dynamic> args = const {},
  ]) async {
    calls.add((method: 'runAction', args: {'id': id, 'args': args}));
    return Map<String, dynamic>.from(runActionResponse);
  }

  @override
  Future<Map<String, dynamic>> runUnit(String unit, List<String> args) async {
    calls.add((method: 'runUnit', args: {'unit': unit, 'args': args}));
    return Map<String, dynamic>.from(runActionResponse);
  }

  @override
  Future<List<String>> knownActions() async {
    calls.add((method: 'knownActions', args: const {}));
    return List.of(knownActionsResponse);
  }

  @override
  Future<List<String>> knownUnits() async {
    calls.add((method: 'knownUnits', args: const {}));
    return const [];
  }

  @override
  Future<Map<String, int>> getValuesByName(List<String> names) async {
    calls.add((method: 'getValuesByName', args: {'names': names}));
    return Map<String, int>.from(getValuesResponse);
  }

  @override
  Future<int?> getValueByName(String name) async {
    calls.add((method: 'getValueByName', args: {'name': name}));
    return getValuesResponse[name];
  }

  @override
  Future<Map<String, int>> allFeaturesAuto() async => const {};

  @override
  Future<Map<String, int>> allKnownFeatures() async => const {};

  @override
  Future<List<String>> subscribePushByNames(List<String> names) async {
    calls.add((method: 'subscribePushByNames', args: {'names': names}));
    return List.of(names);
  }

  @override
  Future<Map<String, String>> labelToCatalog() async => const {};

  @override
  Future<Map<String, dynamic>> registryStats() async {
    calls.add((method: 'registryStats', args: const {}));
    return Map<String, dynamic>.from(registryStatsResponse);
  }

  @override
  Future<Map<String, dynamic>> daemonStatus() async {
    calls.add((method: 'daemonStatus', args: const {}));
    return Map<String, dynamic>.from(daemonStatusResponse);
  }

  @override
  Future<Map<String, dynamic>> carIdentity() async {
    calls.add((method: 'carIdentity', args: const {}));
    return Map<String, dynamic>.from(identityResponse);
  }

  @override
  Future<Map<String, dynamic>> carIdentityLocalOnly() async {
    calls.add((method: 'carIdentityLocalOnly', args: const {}));
    return Map<String, dynamic>.from(identityLocalResponse);
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
    return const {'ok': true};
  }

  @override
  Future<Map<String, dynamic>?> readContentProvider(String family) async {
    calls.add((method: 'readContentProvider', args: {'family': family}));
    return readContentProviderResponse == null
        ? null
        : Map<String, dynamic>.from(readContentProviderResponse!);
  }
}

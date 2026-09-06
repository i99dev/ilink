import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Explicit consent for optional internet features.
/// Analytics, tracking and unrelated account integrations have no flag.
enum OptionalService { downloads, streaming, updates }

abstract interface class ServicePreferences {
  Future<Set<OptionalService>> load();
  Future<void> save(Set<OptionalService> enabled);
}

/// Native transports must stop even while an unrelated preference write waits.
abstract interface class ServiceRevocation {
  Future<void> revoke(OptionalService service);
  void prepareGrant(OptionalService service);
}

class DeviceServicePreferences
    implements ServicePreferences, ServiceRevocation {
  static const key = 'optional_services.v1';
  bool _streamingRevoked = false;

  @override
  Future<void> revoke(OptionalService service) async {
    if (service != OptionalService.streaming) return;
    _streamingRevoked = true;
    await _mirrorStreaming(false);
  }

  @override
  void prepareGrant(OptionalService service) {
    if (service == OptionalService.streaming) _streamingRevoked = false;
  }

  Future<void> _mirrorStreaming(bool enabled) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await const MethodChannel(
        'ilink/tv_ivi',
      ).invokeMethod<void>('setStreamingEnabled', {'enabled': enabled});
    } on MissingPluginException {
      // Non-native test hosts have no player process.
    }
  }

  @override
  Future<Set<OptionalService>> load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final names = prefs.getStringList(key) ?? const <String>[];
      final enabled = OptionalService.values
          .where((s) => names.contains(s.name))
          .toSet();
      await _mirrorStreaming(
        enabled.contains(OptionalService.streaming) && !_streamingRevoked,
      );
      return enabled;
    } catch (_) {
      await _mirrorStreaming(false);
      return <OptionalService>{};
    }
  }

  @override
  Future<void> save(Set<OptionalService> enabled) async {
    if (!enabled.contains(OptionalService.streaming)) {
      await _mirrorStreaming(false);
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setStringList(key, enabled.map((s) => s.name).toList())) {
      throw StateError('Could not save optional service settings');
    }
    await _mirrorStreaming(
      enabled.contains(OptionalService.streaming) && !_streamingRevoked,
    );
  }
}

final servicePreferencesProvider = Provider<ServicePreferences>(
  (_) => DeviceServicePreferences(),
);

class OptionalServicesController extends AsyncNotifier<Set<OptionalService>> {
  Future<void> _pending = Future.value();
  final _revoked = <OptionalService>{};
  final _generation = <OptionalService, int>{};

  @override
  Future<Set<OptionalService>> build() async {
    try {
      return Set.unmodifiable(
        (await ref.watch(servicePreferencesProvider).load()).difference(
          _revoked,
        ),
      );
    } catch (_) {
      return const <OptionalService>{};
    }
  }

  Future<void> setEnabled(OptionalService service, bool enabled) {
    final generation = (_generation[service] ?? 0) + 1;
    _generation[service] = generation;
    final preferences = ref.read(servicePreferencesProvider);
    Future<void>? nativeRevocation;
    if (!enabled) {
      _revoked.add(service);
      if (state.value != null) {
        state = AsyncData(Set.unmodifiable({...state.value!}..remove(service)));
      }
      if (preferences is ServiceRevocation) {
        nativeRevocation = (preferences as ServiceRevocation).revoke(service);
      }
    }
    final operation = Future.wait<void>([_pending, ?nativeRevocation]).then((
      _,
    ) async {
      // An obsolete grant cannot undo a newer revocation.
      if (enabled && _generation[service] != generation) return;
      final current = state.value ?? await future;
      final next = <OptionalService>{...current};
      enabled ? next.add(service) : next.remove(service);
      if (enabled) {
        _revoked.remove(service);
        if (preferences is ServiceRevocation) {
          (preferences as ServiceRevocation).prepareGrant(service);
        }
      }
      // Revoke immediately. Grant only once consent is durably stored.
      if (!enabled) state = AsyncData(Set.unmodifiable(next));
      await preferences.save(next);
      if (ref.mounted) {
        state = AsyncData(Set.unmodifiable(next.difference(_revoked)));
      }
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }
}

final optionalServicesProvider =
    AsyncNotifierProvider<OptionalServicesController, Set<OptionalService>>(
      OptionalServicesController.new,
    );

final serviceEnabledProvider = Provider.family<bool, OptionalService>(
  (ref, service) =>
      ref.watch(optionalServicesProvider).value?.contains(service) ?? false,
);

class ServiceDisabled implements Exception {
  const ServiceDisabled(this.service);
  final OptionalService? service;
  @override
  String toString() => service == null
      ? 'This external integration has been removed.'
      : 'Enable ${service!.name} in Settings > Optional Services.';
}

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/optional_services.dart';
import '../services/service_network_policy.dart';

/// User-enabled downloads and direct internet media; no account transport.
enum DioPurpose { cdn, bare }

final dioProvider = Provider.family<Dio, DioPurpose>((ref, purpose) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );
  final guard = ServiceNetworkInterceptor(
    classify: (request) {
      final host = request.uri.host.toLowerCase();
      if (host == 'i99dash.app' ||
          host.endsWith('.i99dash.app') ||
          host.endsWith('.ondigitalocean.app') ||
          host.endsWith('.digitaloceanspaces.com')) {
        return null;
      }
      final name = request.extra['optionalService'];
      for (final service in OptionalService.values) {
        if (service.name == name) return service;
      }
      return purpose == DioPurpose.cdn ? OptionalService.downloads : null;
    },
    isEnabled: (service) =>
        (ref.read(optionalServicesProvider).value ?? const <OptionalService>{})
            .contains(service),
  );
  dio.interceptors.add(guard);
  ref.listen(optionalServicesProvider, (_, _) => guard.revokeDisabled());
  ref.onDispose(() {
    guard.dispose();
    dio.close(force: true);
  });
  return dio;
});

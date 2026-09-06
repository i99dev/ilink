import 'package:dio/dio.dart';

import 'optional_services.dart';

/// Explicit backend route classification. Unknown routes remain closed until
/// reviewed. Removed tracking endpoints cannot be enabled by another service.
OptionalService? backendServiceFor(String rawPath) => null;

/// Consent enforcement and cancellation independent of any feature controller.
class ServiceNetworkInterceptor extends Interceptor {
  ServiceNetworkInterceptor({required this.classify, required this.isEnabled});
  final OptionalService? Function(RequestOptions) classify;
  final bool Function(OptionalService) isEnabled;
  final Map<RequestOptions, OptionalService> _active = {};

  bool _allowed(OptionalService? service) =>
      service != null && isEnabled(service);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final service = classify(options);
    if (!_allowed(service)) {
      handler.reject(
        DioException(
          requestOptions: options,
          error: ServiceDisabled(service),
          type: DioExceptionType.cancel,
        ),
      );
      return;
    }
    options.cancelToken ??= CancelToken();
    _active[options] = service!;
    handler.next(options);
  }

  void revokeDisabled() {
    for (final request in Map<RequestOptions, OptionalService>.of(
      _active,
    ).entries) {
      if (!_allowed(request.value)) {
        request.key.cancelToken?.cancel(ServiceDisabled(request.value));
        _active.remove(request.key);
      }
    }
  }

  void dispose() {
    for (final request in _active.keys.toList()) {
      request.cancelToken?.cancel('Service disposed');
    }
    _active.clear();
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _active.remove(response.requestOptions);
    final service = classify(response.requestOptions);
    if (!_allowed(service)) {
      handler.reject(
        DioException(
          requestOptions: response.requestOptions,
          type: DioExceptionType.cancel,
          error: ServiceDisabled(service),
        ),
      );
      return;
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _active.remove(err.requestOptions);
    handler.next(err);
  }
}

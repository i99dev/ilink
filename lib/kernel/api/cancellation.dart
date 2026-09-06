import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Returns a fresh [CancelToken] whose lifetime is bound to [ref].
/// Whenever the provider/notifier holding [ref] is disposed (its last
/// listener detaches, or its container is torn down), the token is
/// cancelled — and any `dio.get/post/getStream` call that was passed
/// the token aborts immediately instead of leaking.
///
/// The intended usage from a notifier or async provider:
///
/// ```dart
/// final stations = await ref.read(apiClientProvider).get(
///   '/api/v1/radio/top',
///   cancelToken: ref.cancelOnDispose(),
/// );
/// ```
///
/// Without this, a screen that navigates away mid-request leaves the
/// HTTP call running until the response arrives, holding a connection
/// from the pool and dispatching a result no listener cares about.
extension RefCancellation on Ref {
  CancelToken cancelOnDispose({String? reason}) {
    final token = CancelToken();
    onDispose(() {
      if (!token.isCancelled) token.cancel(reason ?? 'ref disposed');
    });
    return token;
  }
}

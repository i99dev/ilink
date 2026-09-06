/// SDK-internal hook that lets the app inject a *gated* dispatcher
/// (audit + integrity + rate limit + stationary check) without the
/// SDK reaching outward into the app's router code.
///
/// At boot the app overrides [gatedDispatcherProvider] with a function
/// bound to its `CarCommandRouter.dispatch`. When the override is in
/// place, [CarClient.dispatch] routes through it. When not, the SDK
/// falls back to the raw [CarTransport.runAction] path — which is the
/// right behaviour for tests and for branches where the app hasn't
/// wired the safety layer yet.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'car_caller.dart';

/// Function signature the app's gated router exposes to the SDK.
/// Matches [CarClient.dispatch] verbatim so the override can be a
/// bound method on the app's router.
typedef GatedDispatcher =
    Future<Map<String, Object?>> Function(
      String actionId,
      Map<String, dynamic> args, {
      CarCaller? caller,
    });

/// Null by default — SDK falls back to ungated [runAction] when the
/// app hasn't installed a gate. App overrides this at boot:
///
/// ```dart
/// gatedDispatcherProvider.overrideWith((ref) {
///   final router = ref.read(carCommandRouterProvider);
///   return (action, args, {caller}) =>
///       router.dispatch(action, args, caller: caller);
/// });
/// ```
final gatedDispatcherProvider = Provider<GatedDispatcher?>((_) => null);

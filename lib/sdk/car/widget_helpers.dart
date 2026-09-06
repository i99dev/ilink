/// Widget-side ergonomics for consuming the SDK.
///
/// Reduces boilerplate at every call site — instead of:
///
/// ```dart
/// final v = ref.watch(featureValueProvider(name)).maybeWhen(
///   data: (v) => v, orElse: () => null);
/// ```
///
/// just:
///
/// ```dart
/// final v = ref.watchFeatureInt(name);
/// ```
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

extension SdkWidgetRef on WidgetRef {
  /// Sync read of a feature's current int value. Returns null when:
  ///   - the SDK is still loading the initial seed
  ///   - the feature isn't bound on this car (or trim)
  ///   - the underlying push stream errored
  ///
  /// Widgets render their "no data" branch on null. This is the
  /// universal pattern across all SDK consumers — same null
  /// semantics every widget treats as "feature unavailable".
  int? watchFeatureInt(String name) => watch(
    featureValueProvider(name),
  ).maybeWhen(data: (v) => v, orElse: () => null);

  /// Variant for when the consumer cares about the loading state
  /// distinct from "no value" — e.g. show a spinner during the
  /// initial seed but render "—" once we know there's no value.
  AsyncValue<int?> watchFeature(String name) =>
      watch(featureValueProvider(name));
}

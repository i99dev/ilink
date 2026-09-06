/// Minimal caller-identity marker the SDK accepts on gated writes
/// ([CarClient.dispatch]). The SDK only cares about the audit label;
/// the app builds richer subclasses (host-UI, voice, MQTT, dev bench)
/// that add scope semantics on top.
///
/// Keep this surface tiny — anything bigger (scope sets, identity
/// chains) belongs to the app's consumer layer, not to the SDK.
library;

import 'package:flutter/foundation.dart' show immutable;

/// Stable identifier the SDK forwards to the brand client's audit log.
/// Implementations must return a snake_case label that matches the
/// regex `[a-z][a-z0-9_]*` so log aggregators don't have to
/// quote-escape it.
@immutable
abstract class CarCaller {
  const CarCaller();

  String get kindLabel;
}

/// SDK runtime config — the small set of flags the SDK needs to honour
/// at construct time. The app injects values via Riverpod overrides at
/// boot so the SDK never reaches outward into the app's `AppConfig`
/// graph.
///
/// **Override at boot:**
///
/// ```dart
/// ProviderScope(
///   overrides: [
///     sdkConfigProvider.overrideWith((_) => SdkConfig(
///           mockCar: appConfig.mockCar,
///         )),
///   ],
///   child: ...,
/// );
/// ```
///
/// Keep the surface tiny. Anything bigger than a handful of bool/enum
/// flags belongs to the app, not the SDK — pass it as a function arg
/// to the API that needs it instead.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

class SdkConfig {
  const SdkConfig({this.mockCar = false});

  /// When true, [CarBridge] short-circuits every native call and returns
  /// canned data. Used by Storybook / SSR / widget tests where the
  /// platform channel isn't bound. Default `false` — production reads
  /// the host's encrypted action table.
  final bool mockCar;

  static const defaults = SdkConfig();
}

/// App overrides this at boot via [Provider.overrideWith]. Default value
/// is `mockCar=false` so the SDK works out of the box in production
/// scenarios; tests and dev surfaces flip it explicitly.
final sdkConfigProvider = Provider<SdkConfig>((_) => SdkConfig.defaults);

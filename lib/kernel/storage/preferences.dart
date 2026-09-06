import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Synchronous [SharedPreferences] handle, shared app-wide.
///
/// The real instance is injected from `main()` after
/// `SharedPreferences.getInstance()` resolves — anyone reading this without
/// that override has misconfigured the app.
///
/// History: this used to live at radio feature scope with a note to
/// "promote to core/storage the moment a second feature needs it". The TV
/// feature is that second consumer (favourites + catalog cache), so it now
/// lives in `kernel/storage`. `features/radio/providers.dart` re-exports it
/// so existing radio imports keep resolving unchanged.
final sharedPreferencesProvider = Provider<SharedPreferences>((_) {
  throw UnimplementedError(
    'sharedPreferencesProvider must be overridden in main() with a '
    'pre-loaded SharedPreferences instance.',
  );
});

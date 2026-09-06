import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/home_screen_shortcut_service.dart';
import 'home_screen_shortcut_service_provider.dart';
import 'mini_app_providers.dart';

/// True iff we should render the "Add to Home Screen" action for the
/// mini-app with id [appId]. Derived from two sources:
///
///   1. The platform/launcher actually supports pinning (Android 8+ with
///      a pin-capable launcher). iOS and older Androids report
///      `unsupported`.
///   2. The app with [appId] is present in the current catalog. A row
///      that was installed locally but has since been delisted from the
///      catalog can't be pinned — the deep-link wouldn't resolve.
///
/// Using `.select` on the catalog provider keeps rebuilds scoped: a
/// catalog refresh that doesn't change this specific app's presence
/// won't rebuild its tile's pin button.
final canPinMiniAppProvider = Provider.family<bool, String>((ref, appId) {
  final status = ref.watch(homeScreenShortcutStatusProvider).value;
  if (status != HomeScreenShortcutStatus.supported) return false;
  return ref.watch(
    miniAppCatalogProvider.select(
      (value) => value.value?.any((app) => app.id == appId) ?? false,
    ),
  );
});

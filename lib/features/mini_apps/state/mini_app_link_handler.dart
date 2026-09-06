import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../platform/deep_link/link_router.dart';
import '../../../kernel/i18n/generated/app_localizations.dart';
import '../domain/mini_app_deep_link.dart';
import '../presentation/launch_mini_app.dart';
import 'mini_app_shortcut_controller.dart';

/// Registers the mini-app URL grammar with the generic [LinkRouter].
///
/// Kept feature-local so the core router never imports mini-app code
/// directly; the root `ProviderScope` wires this into the handler list
/// via [linkHandlersProvider] override.
class MiniAppLinkHandler implements LinkHandler {
  const MiniAppLinkHandler();

  @override
  String? match(Uri uri) => parseMiniAppDeepLink(uri);

  @override
  Future<void> open(BuildContext context, WidgetRef ref, String id) async {
    final app = await ref
        .read(miniAppShortcutControllerProvider.notifier)
        .resolveForLaunch(id);
    if (!context.mounted) return;
    if (app == null) {
      _showUnknownAppSnack(context);
      return;
    }
    // Goes through the shared launcher so the driver-safety gate +
    // min-host-version check behave identically to tapping a tile.
    await openMiniApp(context, ref, app);
  }

  static void _showUnknownAppSnack(BuildContext context) {
    final t = S.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(t.miniAppsDeepLinkUnknownApp),
        duration: const Duration(milliseconds: 2500),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/feature_flags.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../kernel/i18n/locale_controller.dart';
import '../../../app_actions/index.dart';
import '../../domain/mini_app.dart';
import '../../state/mini_app_install_gate.dart';
import '../../state/mini_app_providers.dart';
import '../../state/mini_app_shortcut_controller.dart';
import '../../state/mini_app_shortcut_status_provider.dart';
import '../../state/mini_app_view_mode.dart';
import '../install_feedback.dart';
import '../launch_mini_app.dart';
import 'mini_app_actions_sheet.dart';
import 'mini_app_list_row.dart';
import 'mini_app_status_chips.dart';
import 'mini_app_tile.dart';

/// My Apps tab — only the installed subset, rendered as a launch grid
/// or list (controlled by [miniAppViewModeProvider]).
///
/// Tap launches the installed app directly via [openMiniApp]
/// (driver-safety gate runs first); long-press surfaces the uninstall
/// confirm. The description / permissions modal lives on the Store
/// tab — once an app is installed the user has already seen that
/// context, so launching it should not require an extra tap.
class MyAppsTab extends ConsumerWidget {
  const MyAppsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final apps = ref.watch(installedMiniAppsProvider);
    final lang =
        ref.watch(
          localeControllerProvider.select((a) => a.value?.locale.languageCode),
        ) ??
        Localizations.localeOf(context).languageCode;
    final viewMode = ref.watch(miniAppViewModeProvider);

    if (apps.isEmpty) {
      return _Empty(message: t.miniAppsEmptyInstalled);
    }
    return viewMode == MiniAppViewMode.list
        ? _MyAppsList(apps: apps, lang: lang)
        : _MyAppsGrid(apps: apps, lang: lang);
  }
}

class _MyAppsGrid extends StatelessWidget {
  const _MyAppsGrid({required this.apps, required this.lang});
  final List<MiniApp> apps;
  final String lang;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: apps.length,
      itemBuilder: (ctx, i) {
        final app = apps[i];
        return Consumer(
          builder: (ctx, ref, _) => MiniAppTile(
            app: app,
            languageCode: lang,
            betaBadge: MiniAppStatusChips(app: app),
            onTap: () => openMiniApp(ctx, ref, app),
            onLongPress: () => _openMiniAppActions(ctx, ref, app),
            primary: _PinToHomeAction(app: app),
          ),
        );
      },
    );
  }
}

class _MyAppsList extends StatelessWidget {
  const _MyAppsList({required this.apps, required this.lang});
  final List<MiniApp> apps;
  final String lang;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: apps.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) {
        final app = apps[i];
        return Consumer(
          builder: (ctx, ref, _) => MiniAppListRow(
            app: app,
            languageCode: lang,
            onTap: () => openMiniApp(ctx, ref, app),
            onLongPress: () => _openMiniAppActions(ctx, ref, app),
            trailing: _PinToHomeAction(app: app),
          ),
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 120),
      children: [
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.apps_outage_rounded,
                size: 48,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> confirmMiniAppUninstall(
  BuildContext context,
  WidgetRef ref, {
  required String appId,
}) async {
  final t = S.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(t.miniAppsUninstall),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(t.sessionEndedDismiss),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(t.miniAppsUninstall),
        ),
      ],
    ),
  );
  if (!context.mounted || confirmed != true) return;
  final outcome = await ref
      .read(miniAppInstallGateProvider)
      .uninstall(caller: StoreTabInstaller.instance, appId: appId);
  if (context.mounted) showInstallOutcomeSnack(context, outcome);
}

/// Trailing tile action that pins the mini-app to the OS home screen.
///
/// Hidden entirely when [canPinMiniAppProvider] reports false — on iOS,
/// Android 7 and below, and any launcher that doesn't implement the
/// pin-shortcut API. Keeping visibility driven by a single derived
/// provider means iOS users never see a disabled button and the tile
/// layout stays balanced on devices where the feature isn't available.
class _PinToHomeAction extends ConsumerWidget {
  const _PinToHomeAction({required this.app});

  final MiniApp app;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canPin = ref.watch(canPinMiniAppProvider(app.id));
    if (!canPin) return const SizedBox.shrink();
    final t = S.of(context);
    return IconButton(
      icon: const Icon(Icons.add_to_home_screen_outlined, size: 20),
      tooltip: t.miniAppsAddToHomeScreen,
      visualDensity: VisualDensity.compact,
      onPressed: () => _onPin(context, ref),
    );
  }

  Future<void> _onPin(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final t = S.of(context);
    final outcome = await ref
        .read(miniAppShortcutControllerProvider.notifier)
        .pin(app.id);
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(pinOutcomeMessage(t, outcome)),
        duration: const Duration(milliseconds: 2000),
      ),
    );
  }
}

/// Routes mini-app long-press to either the legacy per-tile sheet or
/// the unified [showAppActionsSheet], gated by
/// [FeatureFlags.unifiedMiniAppActionsSheet]. Default is the legacy
/// path until the unified sheet has soaked on the native-apps tab.
void _openMiniAppActions(BuildContext context, WidgetRef ref, MiniApp app) {
  if (FeatureFlags.unifiedMiniAppActionsSheet) {
    showAppActionsSheet(
      context: context,
      target: MiniAppTarget(
        appId: app.id,
        label: app.localizedName(Localizations.localeOf(context).languageCode),
      ),
    );
    return;
  }
  showMiniAppActionsSheet(
    context,
    ref,
    app: app,
    onOpenOnIvi: () => openMiniApp(context, ref, app),
    onUninstall: () => confirmMiniAppUninstall(context, ref, appId: app.id),
  );
}

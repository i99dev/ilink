import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/i18n/generated/app_localizations.dart';
import '../../../kernel/i18n/locale_controller.dart';
import '../../mini_apps/state/mini_app_view_mode.dart';
import '../domain/native_app.dart';
import '../state/native_app_store_controller.dart';
import 'native_app_details_sheet.dart';
import 'native_app_icon.dart';
import 'native_app_install_action.dart';

/// Native-app Store tab — the owner-facing storefront for third-party
/// native Android apps. Browse the catalog (`GET /api/v1/apps/catalog`)
/// and install with one tap; the install runs the verify-before-install
/// chain and a system consent dialog (decision D2).
///
/// Layout mirrors the mini-app [StoreTab]: grid/list per
/// [miniAppViewModeProvider], pull-to-refresh, loading/error/empty states.
class NativeAppsTab extends ConsumerWidget {
  const NativeAppsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final async = ref.watch(nativeAppStoreProvider);
    final lang =
        ref.watch(
          localeControllerProvider.select((a) => a.value?.locale.languageCode),
        ) ??
        Localizations.localeOf(context).languageCode;
    final viewMode = ref.watch(miniAppViewModeProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Install or update from APK'),
            onPressed: () => _importApk(context, ref),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () =>
                ref.read(nativeAppStoreProvider.notifier).refresh(),
            child: async.when(
              skipLoadingOnRefresh: true,
              skipError: true,
              loading: () => const _CenteredProgress(),
              error: (_, _) => _MessageList(message: t.nativeAppsLoadError),
              data: (apps) {
                if (apps.isEmpty) {
                  return _MessageList(message: t.nativeAppsEmpty);
                }
                return viewMode == MiniAppViewMode.list
                    ? _NativeList(apps: apps, lang: lang)
                    : _NativeGrid(apps: apps, lang: lang);
              },
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _importApk(BuildContext context, WidgetRef ref) async {
    final selected = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['apk'],
    );
    final path = selected?.files.single.path;
    if (path == null || !context.mounted) return;
    final result = await ref
        .read(nativeAppStoreProvider.notifier)
        .importApk(path);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.kind == NativeStoreInstallKind.installing
              ? 'Continue in the Android installer.'
              : result.message ?? 'Unable to import APK.',
        ),
      ),
    );
  }
}

class _NativeGrid extends StatelessWidget {
  const _NativeGrid({required this.apps, required this.lang});
  final List<NativeApp> apps;
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
      itemBuilder: (ctx, i) => _NativeCard(app: apps[i], lang: lang),
    );
  }
}

class _NativeList extends StatelessWidget {
  const _NativeList({required this.apps, required this.lang});
  final List<NativeApp> apps;
  final String lang;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: apps.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) => _NativeRow(app: apps[i], lang: lang),
    );
  }
}

class _NativeCard extends StatelessWidget {
  const _NativeCard({required this.app, required this.lang});
  final NativeApp app;
  final String lang;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => showNativeAppDetails(context, app, lang: lang),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            NativeAppIcon(app: app, lang: lang, size: 48),
            const SizedBox(height: 10),
            Text(
              app.localizedName(lang),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 2),
            Text(
              app.category ?? 'v${app.latestVersionName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: NativeAppInstallButton(
                app: app,
                lang: lang,
                compact: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NativeRow extends StatelessWidget {
  const _NativeRow({required this.app, required this.lang});
  final NativeApp app;
  final String lang;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => showNativeAppDetails(context, app, lang: lang),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            NativeAppIcon(app: app, lang: lang, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    app.localizedName(lang),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    app.category == null || app.category!.isEmpty
                        ? 'v${app.latestVersionName}'
                        : '${app.category} · v${app.latestVersionName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            NativeAppInstallButton(app: app, lang: lang, compact: true),
          ],
        ),
      ),
    );
  }
}

class _CenteredProgress extends StatelessWidget {
  const _CenteredProgress();
  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator());
}

/// A [ListView] (not a [Center]) so pull-to-refresh works even when the
/// only content is a single centered message — mirrors the mini-app Store.
class _MessageList extends StatelessWidget {
  const _MessageList({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 120),
      children: [
        Center(
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

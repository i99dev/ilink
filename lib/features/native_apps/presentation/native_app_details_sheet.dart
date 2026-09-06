import 'package:flutter/material.dart';

import '../../../kernel/i18n/generated/app_localizations.dart';
import '../../mini_apps/presentation/widgets/mini_app_remote_image.dart';
import '../domain/native_app.dart';
import 'native_app_icon.dart';
import 'native_app_install_action.dart';

/// Bottom-sheet details for a native-app store row: icon, name, version,
/// description, screenshot strip, and the Install / Update button.
Future<void> showNativeAppDetails(
  BuildContext context,
  NativeApp app, {
  required String lang,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _NativeAppDetails(app: app, lang: lang),
  );
}

class _NativeAppDetails extends StatelessWidget {
  const _NativeAppDetails({required this.app, required this.lang});

  final NativeApp app;
  final String lang;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final t = S.of(context);
    final name = app.localizedName(lang);
    final desc = app.localizedDescription(lang);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NativeAppIcon(app: app, lang: lang, size: 56),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: theme.textTheme.titleLarge),
                        const SizedBox(height: 4),
                        Text(
                          'v${app.latestVersionName} · ${app.packageId}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        if (app.category != null && app.category!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              app.category!,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  NativeAppInstallButton(app: app, lang: lang),
                ],
              ),
              if (app.screenshots.isNotEmpty) ...[
                const SizedBox(height: 20),
                SizedBox(
                  height: 160,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: app.screenshots.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: AspectRatio(
                        aspectRatio: 16 / 10,
                        child: MiniAppRemoteImage(url: app.screenshots[i]),
                      ),
                    ),
                  ),
                ),
              ],
              if (desc.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(desc, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 16),
              Text(
                t.nativeAppsConsentNote,
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

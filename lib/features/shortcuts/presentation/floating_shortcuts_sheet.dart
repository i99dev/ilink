import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/settings/app_settings.dart';
import '../../../kernel/ui/theme/colors.dart';
import '../../home/presentation/widgets/circle_app_icon.dart';
import '../../home/presentation/widgets/installed_apps_strip.dart' as strip;
import '../../home/state/installed_apps_provider.dart';

/// Bottom sheet behind the "FAB" tool circle on the home Tools strip. Lets the
/// driver pin installed car apps as standalone floating buttons that hover over
/// every app — tap one to open that app instantly, drag it anywhere.
///
/// Toggling writes [AppSettings.floatingAppShortcuts]; the
/// `floatingShortcutsSyncProvider` (watched at the app root) pushes the new set
/// to the native overlay service, so buttons appear/vanish live.
///
/// Follows the same sheet idiom as the Doctor/Network tools (SafeArea →
/// height-capped Column → scrollable body). Replaces the old Settings section
/// + full-page picker now that floating buttons live on the home page.
class FloatingShortcutsSheet extends ConsumerWidget {
  const FloatingShortcutsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider).value;
    final pinned = (settings?.floatingAppShortcuts ?? const <String>[]).toSet();
    final appsAsync = ref.watch(installedAppsProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Floating app buttons',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Pin apps as floating buttons that stay on screen over every '
                'app. Tap a button to open that app instantly — no need to go '
                'back to the app list. Drag a button anywhere to move it.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: cs.onSurfaceVariant,
                ),
              ),
              if (pinned.isNotEmpty) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${pinned.length} pinned',
                    style: const TextStyle(
                      color: AppColors.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Flexible(
                child: appsAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      "Couldn't read the installed apps on this car.",
                      style: TextStyle(color: cs.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  data: (apps) {
                    if (apps.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No launchable apps found.',
                          style: TextStyle(color: cs.onSurfaceVariant),
                          textAlign: TextAlign.center,
                        ),
                      );
                    }
                    return ListView.builder(
                      shrinkWrap: true,
                      itemCount: apps.length,
                      itemBuilder: (_, i) {
                        final app = apps[i];
                        return _AppRow(
                          packageName: app.packageName,
                          label: app.label,
                          iconHash: app.iconHash ?? '',
                          pinned: pinned.contains(app.packageName),
                          enabled: settings != null,
                          onChanged: (want) =>
                              _toggle(ref, settings!, app.packageName, want),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggle(WidgetRef ref, AppSettings settings, String pkg, bool want) {
    final next = settings.floatingAppShortcuts.toList();
    if (want) {
      if (!next.contains(pkg)) next.add(pkg);
    } else {
      next.remove(pkg);
    }
    ref
        .read(settingsProvider.notifier)
        .save(settings.copyWith(floatingAppShortcuts: next));
  }
}

class _AppRow extends ConsumerWidget {
  const _AppRow({
    required this.packageName,
    required this.label,
    required this.iconHash,
    required this.pinned,
    required this.enabled,
    required this.onChanged,
  });

  final String packageName;
  final String label;
  final String iconHash;
  final bool pinned;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref
        .watch(
          strip.pkgIconBytesProvider((
            packageName: packageName,
            iconHash: iconHash,
          )),
        )
        .value;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: pinned,
      onChanged: enabled ? onChanged : null,
      secondary: CircleAppIcon(
        bytes: bytes,
        fallback: label.isNotEmpty ? label[0].toUpperCase() : '?',
        diameter: 40,
        shadow: false,
      ),
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

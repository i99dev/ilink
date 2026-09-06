import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/ui/theme/colors.dart';
import '../../../kernel/i18n/generated/app_localizations.dart';
import '../../settings/presentation/widgets/section_scaffold.dart';
import '../domain/permission_kind.dart';
import '../state/onboarding_controller.dart';
import 'widgets/onboarding_locale_picker.dart';
import 'widgets/permission_tile.dart';
import 'widgets/wireless_debugging_tile.dart';

/// First-launch screen — a single scrollable surface with the locale
/// picker, the per-permission toggles, and a Continue button. Shown
/// only when `settings.onboardingCompletedAt` is null (gated in
/// `lib/main.dart`'s `_Gate`).
class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final state = ref.watch(onboardingControllerProvider);
    final controller = ref.read(onboardingControllerProvider.notifier);

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: SectionScaffold(
          title: t.onboardingTitle,
          subtitle: t.onboardingSubtitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t.onboardingLocaleLabel,
                style: TextStyle(
                  color: cs.outline,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              const OnboardingLocalePicker(),
              const SizedBox(height: 22),
              if (kIsWeb) ...[
                _WebBanner(text: t.onboardingWebBanner),
                const SizedBox(height: 14),
              ],
              for (var i = 0; i < PermissionKind.values.length; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                PermissionTile(
                  kind: PermissionKind.values[i],
                  title: _titleFor(PermissionKind.values[i], t),
                  reason: _reasonFor(PermissionKind.values[i], t),
                  enabled: state.consents[PermissionKind.values[i]] ?? false,
                  onToggle: (v) =>
                      controller.toggle(PermissionKind.values[i], v),
                  result:
                      state.results[PermissionKind.values[i]] ??
                      PermissionRequestResult.idle,
                ),
              ],
              const SizedBox(height: 18),
              // Surfaces AdbBootstrap state. Renders nothing while
              // status is loading; an applied confirmation, a
              // wireless-debugging instruction card, or a failure
              // diagnostic afterwards. Shown above the remote-help
              // hint because if Wireless debugging isn't on,
              // background features (Doze whitelist, continuous
              // location/mic) won't work even after the user accepts
              // every permission below.
              const WirelessDebuggingTile(),
              const SizedBox(height: 18),
              _RemoteHelpHint(text: t.onboardingRemoteHelpHint),
              const SizedBox(height: 18),
              ElevatedButton.icon(
                onPressed: state.isFinishing ? null : controller.finish,
                icon: state.isFinishing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.black,
                          ),
                        ),
                      )
                    : const Icon(Icons.arrow_forward, size: 18),
                label: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    state.isFinishing
                        ? t.onboardingFinishing
                        : t.onboardingContinue,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _titleFor(PermissionKind kind, S t) => switch (kind) {
    PermissionKind.location => t.onboardingPermissionLocationTitle,
    PermissionKind.microphone => t.onboardingPermissionMicrophoneTitle,
    PermissionKind.notifications => t.onboardingPermissionNotificationsTitle,
  };

  static String _reasonFor(PermissionKind kind, S t) => switch (kind) {
    PermissionKind.location => t.onboardingPermissionLocationReason,
    PermissionKind.microphone => t.onboardingPermissionMicrophoneReason,
    PermissionKind.notifications => t.onboardingPermissionNotificationsReason,
  };
}

class _WebBanner extends StatelessWidget {
  const _WebBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.secondary.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.secondary.withAlpha(110)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: AppColors.secondary, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: cs.onSurface, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Discoverable hint about the opt-in remote-help feature. Lives at the
/// bottom of onboarding (above Continue) so users know the toggle
/// exists in Settings → Models → Remote help — without bothering them
/// for an extra permission decision up front (it isn't a permission).
class _RemoteHelpHint extends StatelessWidget {
  const _RemoteHelpHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.accent.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accent.withAlpha(110)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.support_agent, color: AppColors.accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: cs.onSurface, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

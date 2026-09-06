import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/i18n/generated/app_localizations.dart';
import '../../profile/state/local_profile_provider.dart';
import '../data/beta_consent_storage.dart';
import '../domain/mini_app.dart';

/// Shows the one-time beta-consent bottom sheet for [app].
///
/// Returns `true` when the user taps "Continue" (consent granted and
/// persisted), or `false` / `null` when the user taps "Cancel" or
/// dismisses the sheet by swiping.
///
/// Skips showing the sheet entirely when the user already consented
/// for this `(userId, appId, version)` triple and returns `true`
/// immediately — the caller can proceed to launch without waiting for
/// user input on subsequent launches.
Future<bool> showBetaConsentIfNeeded(
  BuildContext context,
  WidgetRef ref,
  MiniApp app,
) async {
  assert(app.isBeta, 'showBetaConsentIfNeeded called on a non-beta app');

  final userId = ref.read(localProfileProvider).value?.id ?? '';
  final storage = ref.read(betaConsentStorageProvider);

  final alreadyConsented = await storage.hasConsented(
    userId: userId,
    appId: app.id,
    version: app.version,
  );
  if (alreadyConsented) return true;

  if (!context.mounted) return false;

  final result = await showModalBottomSheet<bool>(
    context: context,
    // Prevent casual swipe-down from bypassing the disclaimer.
    isDismissible: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _BetaConsentSheet(app: app),
  );

  if (result == true) {
    await storage.recordConsent(
      userId: userId,
      appId: app.id,
      version: app.version,
    );
    return true;
  }
  return false;
}

/// Bottom sheet body rendered by [showBetaConsentIfNeeded].
///
/// Stateless — the consent-persistence logic lives in the calling
/// function. Kept as a separate widget so it can be tested in
/// isolation without needing Riverpod state.
class _BetaConsentSheet extends StatelessWidget {
  const _BetaConsentSheet({required this.app});

  final MiniApp app;

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Title row with BETA chip
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.miniAppsBetaSheetTitle,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const BetaBadge(),
              ],
            ),
            const SizedBox(height: 12),
            // Disclaimer body
            Text(
              t.miniAppsBetaSheetBody,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            // Developer release notes (optional)
            if (app.releaseNotes != null && app.releaseNotes!.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                t.miniAppsBetaSheetReleaseNotesLabel,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.outline,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(app.releaseNotes!, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 24),
            // Action row
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(t.actionCancel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(t.miniAppsBetaSheetContinue),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Small "BETA" pill matching the design system used by [_SafeBadge] in
/// `mini_app_tile.dart`. Rendered in the consent sheet title and on the
/// Store tile. Exposed as a public widget so both locations can import
/// from this file.
class BetaBadge extends StatelessWidget {
  const BetaBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = S.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        t.miniAppsBetaBadge,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onErrorContainer,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

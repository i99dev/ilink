import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/settings/app_settings.dart';
import '../../../kernel/ui/theme/colors.dart';
import '../../settings/presentation/pages/settings_page.dart';

/// Pure rule: show the one-time intro iff settings are loaded, hands-free is
/// OFF, and it's never been shown. Extracted so the decision is unit-tested
/// without a widget tree.
bool shouldShowVoiceIntro(AppSettings? s) =>
    s != null && !s.wakeWordEnabled && s.heyBydIntroSeenAt == null;

/// One-time "Hands-free Hey BYD" introduction, shown on the FIRST mic tap when the
/// driver hasn't turned hands-free on yet. Single decision point + single
/// persisted flag ([AppSettings.heyBydIntroSeenAt]) so the rule lives in one
/// place and the mic-tap handler stays a thin caller.
///
/// Contract: returns true iff it showed the sheet — the caller then INTERCEPTS
/// that tap (no voice turn). It's shown at most once, EVER: the seen flag is
/// stamped the moment the sheet appears (before the await), so a kill mid-sheet
/// still consumes the one-time. Activating turns on the wake word — the
/// existing `onDeviceVoiceAutoArmProvider` reacts and downloads + arms the
/// model; no direct controller call needed.
Future<bool> maybeShowVoiceIntro(BuildContext context, WidgetRef ref) async {
  final s = ref.read(settingsProvider).value;
  // Settings not hydrated yet, OR hands-free already on, OR already shown →
  // never intercept; the mic proceeds normally.
  if (!shouldShowVoiceIntro(s)) return false;
  // Stamp seen up front so the introduction is shown exactly once even if the app is
  // killed while the sheet is open.
  await ref
      .read(settingsProvider.notifier)
      .save(s!.copyWith(heyBydIntroSeenAt: DateTime.now()));
  if (!context.mounted) return true; // consumed the one-time regardless
  await _showVoiceIntroSheet(context, ref);
  return true;
}

Future<void> _showVoiceIntroSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.record_voice_over_rounded,
                      color: AppColors.accent,
                      size: 26,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Local voice commands',
                        style: TextStyle(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Tap the mic for a command, or enable hands-free Hey BYD.',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 16),
                // VOICE — offline commands.
                const _VoiceModeCard(
                  icon: Icons.directions_car_rounded,
                  accent: AppColors.accent,
                  title: 'Voice — say "Hey BYD"',
                  subtitle: 'Instant car commands',
                  bullets: [
                    'Lock, windows, A/C, trunk, climate…',
                    'Runs on the car — works offline',
                    'Uses the installed speech model',
                  ],
                ),
                const SizedBox(height: 10),
                const SizedBox(height: 14),
                _hintRow(
                  cs,
                  Icons.touch_app_rounded,
                  'No wake word? Tap the mic to give a local command.',
                ),
                const SizedBox(height: 8),
                _hintRow(
                  cs,
                  Icons.download_rounded,
                  'English speech is bundled with the app. Other supported models '
                  'can be downloaded with your permission.',
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Not now'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () async {
                        final nav = Navigator.of(ctx);
                        final cur = ref.read(settingsProvider).value;
                        if (cur != null &&
                            (!cur.wakeWordEnabled ||
                                !cur.voiceAssistantEnabled)) {
                          // Enable voice + hands-free so the autoarm provider
                          // downloads the model + starts the "Hey BYD" loop.
                          await ref
                              .read(settingsProvider.notifier)
                              .save(
                                cur.copyWith(
                                  voiceAssistantEnabled: true,
                                  wakeWordEnabled: true,
                                ),
                              );
                        }
                        nav.pop(); // close the sheet
                        // Land on the voice settings so the model download +
                        // language picker are visible — otherwise the download
                        // runs silently and feels like nothing happened.
                        unawaited(
                          nav.push(
                            MaterialPageRoute(
                              builder: (_) => const SettingsPage(
                                initialSectionId: 'appearance',
                              ),
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.mic_rounded, size: 18),
                      label: const Text('Turn on hands-free'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _VoiceModeCard extends StatelessWidget {
  const _VoiceModeCard({
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.bullets,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String subtitle;
  final List<String> bullets;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: accent, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(color: accent, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final b in bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.check_rounded,
                    size: 15,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      b,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.25,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

Widget _hintRow(ColorScheme cs, IconData icon, String text) => Row(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Icon(icon, color: cs.onSurfaceVariant, size: 16),
    const SizedBox(width: 8),
    Expanded(
      child: Text(
        text,
        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12, height: 1.3),
      ),
    ),
  ],
);

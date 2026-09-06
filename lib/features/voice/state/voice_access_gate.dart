import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:ilink/kernel/i18n/generated/app_localizations.dart';
import 'package:ilink/kernel/settings/app_settings.dart';
import 'voice_controller.dart';

sealed class VoiceAccess {
  const VoiceAccess();
}

class VoiceAccessUnlocked extends VoiceAccess {
  const VoiceAccessUnlocked();
}

class VoiceAccessDisabledByUser extends VoiceAccess {
  const VoiceAccessDisabledByUser();
}

VoiceAccess _access(bool enabled) =>
    enabled ? const VoiceAccessUnlocked() : const VoiceAccessDisabledByUser();
VoiceAccess resolveVoiceAccess(WidgetRef ref) => _access(
  ref.watch(settingsProvider).value?.voiceAssistantEnabled ??
      AppSettings.defaultVoiceAssistantEnabled,
);
VoiceAccess resolveVoiceAccessFromRef(Ref ref) => _access(
  ref.read(settingsProvider).value?.voiceAssistantEnabled ??
      AppSettings.defaultVoiceAssistantEnabled,
);
final voiceAccessGateProvider = Provider<VoiceAccess>(
  (ref) => _access(
    ref.watch(settingsProvider).value?.voiceAssistantEnabled ??
        AppSettings.defaultVoiceAssistantEnabled,
  ),
);
final voiceAccessOpenProvider = Provider<bool>(
  (ref) => ref.watch(voiceAccessGateProvider) is VoiceAccessUnlocked,
);
final voiceVisibilityProvider = Provider<bool>(
  (ref) => ref.watch(voiceAccessOpenProvider),
);
bool canStartVoice(Ref ref) =>
    resolveVoiceAccessFromRef(ref) is VoiceAccessUnlocked;
Future<void> startVoiceWithGate(BuildContext context, WidgetRef ref) async {
  if (resolveVoiceAccess(ref) is! VoiceAccessUnlocked) return;
  if (!await ensureMicPermission(context, ref) || !context.mounted) return;
  await ref.read(voiceControllerProvider.notifier).start();
}

Future<bool> startVoiceFromHandler(Ref ref) async {
  if (!canStartVoice(ref)) return false;
  await ref.read(voiceControllerProvider.notifier).start();
  return true;
}

bool _micPermissionSheetOpen = false;

/// Probe + request mic permission. Returns:
///   * true  — granted (caller should proceed to start voice).
///   * false — denied / permanently denied (caller bails; this method
///     already surfaced the appropriate sheet).
///
/// Idempotent: if the permission sheet is already open from a sibling
/// tap, this returns false without re-showing — prevents three
/// concurrent overlays when the user mashes mic surfaces.
Future<bool> ensureMicPermission(BuildContext context, WidgetRef ref) async {
  final status = await Permission.microphone.status;
  if (status.isGranted) return true;

  // Try a fresh request first (covers the never-asked + denied-once
  // cases). Permanently-denied returns the same denied status without
  // re-prompting.
  final next = await Permission.microphone.request();
  if (next.isGranted) return true;

  if (!context.mounted) return false;
  if (_micPermissionSheetOpen) return false;
  _micPermissionSheetOpen = true;
  try {
    await _showMicPermissionSheet(
      context,
      isPermanentlyDenied: next.isPermanentlyDenied,
    );
  } finally {
    _micPermissionSheetOpen = false;
  }
  return false;
}

Future<void> _showMicPermissionSheet(
  BuildContext context, {
  required bool isPermanentlyDenied,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      final t = S.of(ctx);
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
                    Icon(Icons.mic_off_rounded, color: cs.onSurface, size: 24),
                    const SizedBox(width: 10),
                    Text(
                      t.voiceAccessMicTitle,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  isPermanentlyDenied
                      ? t.voiceAccessMicPermanentlyDeniedBody
                      : t.voiceAccessMicPermissionBody,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: Text(t.actionCancel),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () async {
                        await openAppSettings();
                        if (ctx.mounted) Navigator.of(ctx).pop();
                      },
                      icon: const Icon(Icons.settings_outlined, size: 18),
                      label: Text(t.voiceAccessOpenSettings),
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

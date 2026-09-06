import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/settings/app_settings.dart';
import 'ondevice_voice_controller.dart';

final onDeviceVoiceAutoArmProvider = Provider<void>((ref) {
  ref.listen<({bool voiceEnabled, bool wake, String lang})>(
    settingsProvider.select(
      (s) => (
        voiceEnabled:
            s.value?.voiceAssistantEnabled ??
            AppSettings.defaultVoiceAssistantEnabled,
        wake: s.value?.wakeWordEnabled ?? false,
        lang: s.value?.voiceModelLang ?? 'en-us',
      ),
    ),
    (prev, next) async {
      final controller = ref.read(onDeviceVoiceControllerProvider.notifier);

      // Voice disabled entirely → release everything.
      if (!next.voiceEnabled) {
        unawaited(controller.disarm());
        return;
      }

      if (next.wake) {
        // Hands-free: arm (provisions the model + runs the loop). If the
        // language changed while armed, disarm first so arm() re-provisions
        // for the new language.
        if (prev != null && prev.wake && prev.lang != next.lang) {
          await controller.disarm();
        }
        unawaited(controller.arm());
        return;
      }

      // Manual-only (voice on, Hey BYD off): don't run the mic loop, but make
      // sure the model is downloaded so a mic TAP can dispatch on-device. If we
      // were armed (Hey BYD just turned off), release the loop first.
      if (prev != null && prev.wake) await controller.disarm();
      unawaited(controller.ensureModelReady());
    },
    fireImmediately: true,
  );
});

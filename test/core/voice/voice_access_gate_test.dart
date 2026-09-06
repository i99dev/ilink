import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/settings/app_settings.dart';
import 'package:ilink/features/voice/state/voice_access_gate.dart';

final _accessProbe = Provider<VoiceAccess>(resolveVoiceAccessFromRef);
final _canStartProbe = Provider<bool>(canStartVoice);

class _Settings extends SettingsController {
  _Settings(this.enabled);
  final bool enabled;
  @override
  Future<AppSettings> build() async =>
      AppSettings.empty.copyWith(voiceAssistantEnabled: enabled);
}

void main() {
  for (final enabled in [true, false]) {
    test('local voice follows the user toggle ($enabled)', () async {
      final container = ProviderContainer(
        overrides: [settingsProvider.overrideWith(() => _Settings(enabled))],
      );
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);
      expect(container.read(_canStartProbe), enabled);
      expect(container.read(voiceVisibilityProvider), enabled);
      expect(
        container.read(_accessProbe),
        enabled ? isA<VoiceAccessUnlocked>() : isA<VoiceAccessDisabledByUser>(),
      );
    });
  }
}

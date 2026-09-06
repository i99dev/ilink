import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/voice/presentation/voice_intro_gate.dart';
import 'package:ilink/kernel/settings/app_settings.dart';

/// The one-time "Hey BYD" intro rule: show iff settings are loaded, hands-free
/// is OFF, and it's never been shown. (The sheet UI itself is a thin shell
/// around this predicate.)
void main() {
  const base = AppSettings(deviceId: 'V');

  group('shouldShowVoiceIntro', () {
    test('shows when hands-free off and never seen', () {
      expect(
        shouldShowVoiceIntro(base.copyWith(wakeWordEnabled: false)),
        isTrue,
      );
    });

    test('does NOT show when hands-free already on', () {
      expect(
        shouldShowVoiceIntro(base.copyWith(wakeWordEnabled: true)),
        isFalse,
      );
    });

    test('does NOT show once already seen (one-time, ever)', () {
      final seen = base.copyWith(
        wakeWordEnabled: false,
        heyBydIntroSeenAt: DateTime.utc(2026, 6, 14),
      );
      expect(shouldShowVoiceIntro(seen), isFalse);
    });

    test('does NOT show before settings hydrate (null)', () {
      expect(shouldShowVoiceIntro(null), isFalse);
    });
  });
}

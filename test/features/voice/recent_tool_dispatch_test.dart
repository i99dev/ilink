import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/voice/state/voice_controller.dart';

/// Coverage for the on-device command confirmation chip. The silent-command
/// UX (no TTS, no transcript) leans on this transient state being surfaced
/// so the driver still gets a glanceable "done" — these assert it carries
/// the right shape for the floating-mic pill to render the success style.
void main() {
  group('RecentToolDispatchNotifier.confirmLocalCommand', () {
    test('publishes an on-device-confirmed dispatch with a friendly label', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      expect(c.read(recentToolDispatchProvider), isNull);

      c
          .read(recentToolDispatchProvider.notifier)
          .confirmLocalCommand(
            commandId: 'door.lock',
            arguments: const {},
            label: 'Lock',
          );

      final d = c.read(recentToolDispatchProvider);
      expect(d, isNotNull);
      expect(d!.onDeviceConfirmed, isTrue);
      expect(d.toolName, 'door.lock');
      expect(d.label, 'Lock');
      // predictiveFired true keeps the chip in the "already happened" lane;
      // onDeviceConfirmed is what flips the pill to the success style.
      expect(d.predictiveFired, isTrue);
    });

    test('label is optional — null falls back to the tool name in the UI', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      c
          .read(recentToolDispatchProvider.notifier)
          .confirmLocalCommand(
            commandId: 'light.find_car',
            arguments: const {'on': true},
          );

      final d = c.read(recentToolDispatchProvider)!;
      expect(d.label, isNull);
      expect(d.onDeviceConfirmed, isTrue);
      expect(d.arguments, const {'on': true});
    });
  });
}

import 'package:ilink/kernel/config/app_config.dart';
import 'package:ilink/kernel/config/config_provider.dart';
import 'package:ilink/kernel/settings/app_settings.dart';
import 'package:ilink/sdk/car/identity/car_device_id.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Compile-time AppConfig the SettingsController reads (for mockCar).
// Mirrors the shape used by other Riverpod-driven tests in the repo;
// fields are filler — only mockCar matters to this suite.
const _testConfig = AppConfig(
  env: AppEnv.dev,
  mockCar: true,

  daemonHost: '127.0.0.1',
  daemonPort: 0,
  adbdPort: 0,
  logLevel: LogLevel.debug,
);

// Override the *effective* AppConfig provider directly. Going through
// the base provider triggers the runtime-backend-override chain, which
// reads settings to seed itself — circular at test build time even
// though production gets away with it via the AsyncData lazy load.
ProviderContainer _container() => ProviderContainer(
  overrides: [
    appConfigBaseProvider.overrideWithValue(_testConfig),
    appConfigProvider.overrideWithValue(_testConfig),
  ],
);

// ── flutter_secure_storage mock ──
// `flutter_secure_storage` is a platform-channel plugin that can't run
// under `flutter test`, so we install an in-memory mock handler on its
// method channel (the same approach `license_store_test.dart` uses).
// This lets the REAL [AuthTokenStore] inside SettingsController round-
// trip the auth secrets so the migration path is exercised end-to-end.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings model', () {
    test('copyWith preserves unspecified fields', () {
      const s = AppSettings(deviceId: 'V', voiceAllowInterrupt: true);
      final n = s.copyWith(deviceId: 'W');
      expect(n.deviceId, 'W');
      expect(n.userId, 'local-device');
      expect(n.voiceAllowInterrupt, isTrue);
    });

    test('defaults are stable — UI surfaces compare against these', () {
      expect(AppSettings.defaultOpenAiVoice, 'alloy');
      expect(AppSettings.defaultVoiceVadMode, VoiceVadMode.semantic);
      // Every VAD mode round-trips through the string the UI persists.
      expect(parseVoiceVadMode('semantic'), VoiceVadMode.semantic);
      expect(parseVoiceVadMode('server'), VoiceVadMode.server);
      expect(parseVoiceVadMode('ptt'), VoiceVadMode.ptt);
      // Unknown / legacy strings fall back to the default instead of throwing.
      expect(parseVoiceVadMode('nonsense'), VoiceVadMode.semantic);
      expect(parseVoiceVadMode(null), VoiceVadMode.semantic);
    });
  });

  group('SettingsController persistence', () {
    // SharedPreferences.setMockInitialValues wires the prefs plugin's
    // method channel to an in-memory map; the secure-storage mock backs
    // the auth secrets, which now live in the Keystore (not prefs).
    setUp(() {
      SharedPreferences.setMockInitialValues(const {});
    });

    test('build() returns empty-ish defaults when prefs are clean', () async {
      final c = _container();
      addTearDown(c.dispose);
      final s = await c.read(settingsProvider.future);
      expect(s.userId, 'local-device');
      // Debug-mode builds (which tests are) seed a stable dev VIN on
      // first launch when prefs hold none — see SettingsController.build.
      // The seeded VIN is what /account on the backend will echo back,
      // and what currentCarProvider matches against, so dev work is
      // end-to-end consistent without typing a VIN in Settings.
      expect(s.deviceId, isNotEmpty);
      // The seeded id MUST be the canonical mock id the bridge / pairing /
      // MQTT creds use — a divergence desyncs the creds username from
      // settings.deviceId and the MQTT client refuses to connect.
      expect(s.deviceId, CarDeviceId.mockDeviceId);
      expect(s.voiceVadMode, AppSettings.defaultVoiceVadMode);
      expect(s.voiceAllowInterrupt, isFalse);
    });

    test('MIGRATION: a legacy mock device id is repaired to the canonical '
        'mock id on build (mockCar)', () async {
      // A pre-fix build persisted the old placeholder, which mismatched
      // the bridge-minted MQTT creds and blocked the MQTT connection.
      SharedPreferences.setMockInitialValues(const {
        'deviceId': 'byd:DEV0DASH00000DEV1',
      });
      final c = _container();
      addTearDown(c.dispose);
      final s = await c.read(settingsProvider.future);

      // Settings now carry the canonical mock id…
      expect(s.deviceId, CarDeviceId.mockDeviceId);
      // …and the migration is persisted so it survives the next launch.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('deviceId'), CarDeviceId.mockDeviceId);
    });

    test('build() hydrates local preferences', () async {
      SharedPreferences.setMockInitialValues(const {
        // Storage key is `'deviceId'` post-rename (AppSettings._kDeviceId).
        'deviceId': 'LX001',
        'voice_vad_mode': 'ptt',
        'voice_vad_threshold': 0.42,
        'voice_allow_interrupt': true,
      });
      // userId now lives in the secure store, not prefs — seed it there.
      final c = _container();
      addTearDown(c.dispose);
      final s = await c.read(settingsProvider.future);
      expect(s.userId, 'local-device');
      expect(s.deviceId, 'LX001');
      expect(s.voiceVadMode, VoiceVadMode.ptt);
      expect(s.voiceVadThreshold, 0.42);
      expect(s.voiceAllowInterrupt, isTrue);
    });

    test('activeThemeId defaults to empty (inert) and persists', () async {
      final c = _container();
      addTearDown(c.dispose);
      final initial = await c.read(settingsProvider.future);
      // Empty by default = built-in look, feature ships inert.
      expect(initial.activeThemeId, AppSettings.defaultActiveThemeId);
      expect(initial.activeThemeId, '');

      await c
          .read(settingsProvider.notifier)
          .save(initial.copyWith(activeThemeId: 'neon'));
      expect(c.read(settingsProvider).value?.activeThemeId, 'neon');

      // A fresh container hydrates the persisted id.
      final c2 = _container();
      addTearDown(c2.dispose);
      final reloaded = await c2.read(settingsProvider.future);
      expect(reloaded.activeThemeId, 'neon');
    });

    test('build() hydrates activeThemeId from seeded prefs', () async {
      SharedPreferences.setMockInitialValues(const {
        'active_theme_id': 'daylight',
      });
      final c = _container();
      addTearDown(c.dispose);
      final s = await c.read(settingsProvider.future);
      expect(s.activeThemeId, 'daylight');
    });

    test('copyWith preserves activeThemeId when unspecified', () {
      const s = AppSettings(deviceId: 'V', activeThemeId: 'neon');
      expect(s.copyWith(deviceId: 'changed-device').activeThemeId, 'neon');
    });

    test(
      'customWakePhrases default empty, persist + reload as a list',
      () async {
        final c = _container();
        addTearDown(c.dispose);
        final initial = await c.read(settingsProvider.future);
        expect(initial.customWakePhrases, isEmpty);

        await c
            .read(settingsProvider.notifier)
            .save(
              initial.copyWith(
                customWakePhrases: const ['مرحبا بايدي', 'ok byd'],
              ),
            );
        expect(c.read(settingsProvider).value?.customWakePhrases, [
          'مرحبا بايدي',
          'ok byd',
        ]);

        // Fresh container hydrates the persisted StringList in order.
        final c2 = _container();
        addTearDown(c2.dispose);
        final reloaded = await c2.read(settingsProvider.future);
        expect(reloaded.customWakePhrases, ['مرحبا بايدي', 'ok byd']);
      },
    );

    test('build() hydrates customWakePhrases from seeded prefs', () async {
      SharedPreferences.setMockInitialValues(const {
        'custom_wake_phrases': ['يا بايدي'],
      });
      final c = _container();
      addTearDown(c.dispose);
      final s = await c.read(settingsProvider.future);
      expect(s.customWakePhrases, ['يا بايدي']);
    });

    test('copyWith preserves customWakePhrases when unspecified', () {
      const s = AppSettings(deviceId: 'V', customWakePhrases: ['hey byd']);
      expect(s.copyWith(deviceId: 'changed-device').customWakePhrases, [
        'hey byd',
      ]);
    });

    test(
      'floatingAppShortcuts default empty, persist + reload as a list',
      () async {
        final c = _container();
        addTearDown(c.dispose);
        final initial = await c.read(settingsProvider.future);
        expect(initial.floatingAppShortcuts, isEmpty);

        await c
            .read(settingsProvider.notifier)
            .save(
              initial.copyWith(
                floatingAppShortcuts: const [
                  'com.google.android.youtube',
                  'com.yandex.yandexmaps',
                ],
              ),
            );

        // Fresh container hydrates the persisted StringList in order.
        final c2 = _container();
        addTearDown(c2.dispose);
        final reloaded = await c2.read(settingsProvider.future);
        expect(reloaded.floatingAppShortcuts, [
          'com.google.android.youtube',
          'com.yandex.yandexmaps',
        ]);
      },
    );

    test('copyWith preserves floatingAppShortcuts when unspecified', () {
      const s = AppSettings(
        deviceId: 'V',
        floatingAppShortcuts: ['com.google.android.youtube'],
      );
      expect(s.copyWith(deviceId: 'changed-device').floatingAppShortcuts, [
        'com.google.android.youtube',
      ]);
    });

    test(
      'heyBydIntroSeenAt defaults null, persists + reloads (one-time)',
      () async {
        final c = _container();
        addTearDown(c.dispose);
        final initial = await c.read(settingsProvider.future);
        expect(initial.heyBydIntroSeenAt, isNull);

        final ts = DateTime.utc(2026, 6, 14, 10, 30);
        await c
            .read(settingsProvider.notifier)
            .save(initial.copyWith(heyBydIntroSeenAt: ts));
        expect(c.read(settingsProvider).value?.heyBydIntroSeenAt, ts);

        // Fresh container hydrates the persisted timestamp (so the upsell
        // never shows again).
        final c2 = _container();
        addTearDown(c2.dispose);
        final reloaded = await c2.read(settingsProvider.future);
        expect(reloaded.heyBydIntroSeenAt, ts);
      },
    );

    test('copyWith preserves heyBydIntroSeenAt when unspecified', () {
      final s = AppSettings(
        deviceId: 'V',
        heyBydIntroSeenAt: DateTime.utc(2026, 1, 1),
      );
      expect(
        s.copyWith(deviceId: 'changed-device').heyBydIntroSeenAt,
        DateTime.utc(2026, 1, 1),
      );
    });
  });
}

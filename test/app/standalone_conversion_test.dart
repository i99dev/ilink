import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ilink/app/access/feature_gate.dart';
import 'package:ilink/app/gate/app_gate.dart';
import 'package:ilink/app/lifecycle/app_listeners.dart';
import 'package:ilink/kernel/access/feature_policy.dart';
import 'package:ilink/kernel/services/optional_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every local feature renders without an account provider', (
    tester,
  ) async {
    for (final feature in Feature.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: FeatureGate(
            feature: feature,
            child: Text('local ${feature.name}'),
          ),
        ),
      );
      expect(find.text('local ${feature.name}'), findsOneWidget);
    }
    expect(kPostSettingsGates.map((gate) => gate.id), ['onboarding']);
    expect(OptionalService.values.map((service) => service.name), [
      'downloads',
      'streaming',
      'updates',
    ]);
  });

  test(
    'upgrade removes retired credentials and preserves local data',
    () async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'old-access',
        'refresh_token': 'old-refresh',
        'user_id': 'old-account',
        'backend_url_override': 'https://retired.invalid',
        'deviceId': 'byd:LOCAL',
        'theme_mode': 'dark',
        'onboarding_completed_at': '2026-01-01T00:00:00Z',
      });
      final secure = <String, String>{
        'auth_tokens_v1': 'old-auth',
        'mqtt_credentials_v1': 'old-mqtt',
        'license_v1.meta': 'old-license',
        'account_snapshot.v1.old': 'old-profile',
        'local_privileged_app_key': 'keep-local-key',
      };
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'readAll') return Map<String, String>.of(secure);
        if (call.method == 'delete') {
          secure.remove((call.arguments as Map)['key']);
          return null;
        }
        throw StateError('Unexpected secure-storage action: ${call.method}');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(bootWipeResumeProvider.future);
      final prefs = await SharedPreferences.getInstance();
      expect(secure, {'local_privileged_app_key': 'keep-local-key'});
      expect(prefs.getString('deviceId'), 'byd:LOCAL');
      expect(prefs.getString('theme_mode'), 'dark');
      expect(prefs.getString('onboarding_completed_at'), isNotNull);
      for (final key in [
        'access_token',
        'refresh_token',
        'user_id',
        'backend_url_override',
      ]) {
        expect(prefs.containsKey(key), isFalse);
      }
      expect(prefs.getBool('standalone_credentials_removed.v1'), isTrue);
    },
  );
}

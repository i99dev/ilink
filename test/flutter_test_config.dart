import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Suite-wide test bootstrap. `flutter test` auto-discovers this file and
/// runs [testExecutable] around every test file's `main()`.
///
/// Why this exists: `flutter_secure_storage` is a platform-channel plugin
/// with no headless implementation. An UNHANDLED `read`/`write` call on the
/// test binary messenger does not throw or return — it hangs the isolate.
/// Since `SettingsController.build()` now hydrates the auth secrets from
/// Keystore-backed secure storage (audit P0 #6), ANY test that builds the
/// real controller (`settingsProvider.future`) — themes, runtime-backend
/// override, onboarding, license, etc. — would otherwise wedge `flutter
/// test` waiting on that channel.
///
/// Installing a single default in-memory mock here makes secure storage
/// behave like an empty (then writable) store for the whole suite. Files
/// that exercise the secrets directly (`app_settings_test`,
/// `auth_token_store_test`, `force_token_refresh_test`, `license_store_test`)
/// still install their own per-test handler on the same channel in `setUp`,
/// which simply replaces this default — no conflict.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final backing = <String, String>{};

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureChannel, (call) async {
        final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
        final key = args['key'] as String?;
        switch (call.method) {
          case 'write':
            backing[key!] = args['value'] as String;
            return null;
          case 'read':
            return backing[key];
          case 'delete':
            backing.remove(key);
            return null;
          case 'readAll':
            return Map<String, String>.from(backing);
          case 'deleteAll':
            backing.clear();
            return null;
          case 'containsKey':
            return backing.containsKey(key);
          default:
            return null;
        }
      });

  await testMain();
}

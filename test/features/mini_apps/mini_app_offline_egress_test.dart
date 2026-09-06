import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/mini_apps/presentation/mini_app_viewer.dart';

void main() {
  bool allowed(String uri, {bool enabled = false}) =>
      miniAppRequestAllowedWithConsent(
        Uri.parse(uri),
        installRoot: Uri.parse('file:///data/mini-app/'),
        networkOrigins: ['https://api.example.com'],
        networkEnabled: enabled,
      );
  test('local assets stay available while optional downloads are off', () {
    expect(allowed('file:///data/mini-app/app.js'), isTrue);
    expect(allowed('data:text/plain,local'), isTrue);
    expect(allowed('file:///data/another-app/app.js'), isFalse);
    expect(allowed('file:///data/mini-app/%2e%2e/secret'), isFalse);
    expect(allowed('file://remote-server/data/mini-app/app.js'), isFalse);
  });
  test('declared and global origins require opt-in', () {
    expect(allowed('https://api.example.com/data'), isFalse);
    expect(allowed('https://miniapps.ilink.app/app.js'), isFalse);
    expect(allowed('wss://api.example.com/live'), isFalse);
    expect(allowed('https://api.example.com/data', enabled: true), isTrue);
    expect(allowed('https://other.example.com/data', enabled: true), isFalse);
  });
  test('offline scripts do not retain allowlisted remote CSP origins', () {
    final script = brandedGlobalAliasUserScripts(
      networkOrigins: ['https://api.example.com'],
    ).first.source;
    expect(script, isNot(contains('https://api.example.com')));
    expect(script, contains('WebSocket'));
    expect(script, contains('EventSource'));
    expect(script, contains('SharedWorker'));
    expect(script, contains('writable:false,configurable:false'));
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/update/data/apk_signer_check.dart';
import 'package:ilink/kernel/update/data/ota_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, dynamic> platformResult;
  final check = ApkSignerCheck();
  setUp(() {
    platformResult = {
      'ok': true,
      'expected': 'a' * 64,
      'actual': 'a' * 64,
      'packageName': 'com.i99dev.ilink',
      'versionCode': 100,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          otaMethodChannel,
          (_) async => platformResult,
        );
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(otaMethodChannel, null),
  );

  Future<void> verify() => check.verify(
    '/local/app.apk',
    expectedPackage: 'com.i99dev.ilink',
    expectedVersionCode: 100,
  );

  test('accepts matching on-device signer, package and build', () async {
    await verify();
  });
  test('rejects missing pin even if old native helper returned ok', () async {
    platformResult['expected'] = '';
    await expectLater(verify(), throwsA(isA<OtaSignerMismatchException>()));
  });
  test('rejects a different signing certificate', () async {
    platformResult['actual'] = 'b' * 64;
    await expectLater(verify(), throwsA(isA<OtaSignerMismatchException>()));
  });
  test('rejects a signed APK for a different package', () async {
    platformResult['packageName'] = 'other.app';
    await expectLater(verify(), throwsStateError);
  });
  test('rejects misleading version metadata', () async {
    platformResult['versionCode'] = 99;
    await expectLater(verify(), throwsStateError);
  });
}

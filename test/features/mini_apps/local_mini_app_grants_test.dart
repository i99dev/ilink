import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ilink/features/mini_apps/data/local_mini_app_grants.dart';
import 'package:ilink/features/mini_apps/data/mini_app_install_storage.dart';

void main() {
  const hashA =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const hashB =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  late MiniAppInstallStorage installs;
  late LocalMiniAppGrants grants;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    installs = MiniAppInstallStorage(SharedPreferences.getInstance);
    grants = LocalMiniAppGrants(SharedPreferences.getInstance, installs);
  });
  test('approval alone cannot grant an uninstalled or different app', () async {
    await grants.approve('app', hashA, {'pkg.read'});
    expect(await grants.allows('app', hashA, 'pkg.read'), false);
    await installs.install('other', bundleSha256: hashA);
    expect(await grants.allows('other', hashA, 'pkg.read'), false);
  });
  test(
    'only explicitly granted scope and exact installed bytes are allowed',
    () async {
      await installs.install('app', bundleSha256: hashA);
      expect(await grants.allows('app', hashA, 'pkg.read'), false);
      await grants.approve('app', hashA, {'pkg.read'});
      expect(await grants.allows('app', hashA, 'pkg.read'), true);
      expect(await grants.allows('app', hashA, 'pkg.launch'), false);
      expect(await grants.allows('app', null, 'pkg.read'), false);
      await installs.updateBundleSha('app', hashB);
      expect(await grants.allows('app', hashA, 'pkg.read'), false);
      expect(await grants.allows('app', hashB, 'pkg.read'), false);
    },
  );
  test('revocation and uninstall immediately deny further calls', () async {
    await installs.install('app', bundleSha256: hashA);
    await grants.approve('app', hashA, {'car.read'});
    await grants.revoke('app', hashA);
    expect(await grants.allows('app', hashA, 'car.read'), false);
    await grants.approve('app', hashA, {'car.read'});
    await installs.uninstall('app');
    expect(await grants.allows('app', hashA, 'car.read'), false);
  });
  test('invalid hashes and unknown or wildcard permissions reject', () async {
    await expectLater(
      grants.approve('app', '', {'car.read'}),
      throwsFormatException,
    );
    await expectLater(
      grants.approve('app', hashA, {'*'}),
      throwsFormatException,
    );
    await expectLater(
      grants.approve('app', hashA, {'_admin.exec'}),
      throwsFormatException,
    );
  });
  test(
    'empty scope selection is valid explicit consent with no capability',
    () async {
      await installs.install('app', bundleSha256: hashA);
      await grants.approve('app', hashA, {});
      expect(await grants.approved('app', hashA), isEmpty);
      expect(await grants.allows('app', hashA, 'car.read'), false);
    },
  );
  test('direct bridge operations map read and mutation scopes separately', () {
    expect(directBridgeScope('car.command'), 'car.write');
    expect(directBridgeScope('car.identity'), 'car.read');
    expect(directBridgeScope('workflow.list'), 'workflow.read');
    expect(directBridgeScope('workflow.test'), 'workflow.write');
    expect(directBridgeScope('workflow.setEnabled'), 'workflow.write');
    expect(directBridgeScope('location.read'), 'location.read');
    expect(directBridgeScope('_admin.exec'), isNull);
  });
}

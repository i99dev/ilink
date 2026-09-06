import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ilink/features/mini_apps/data/mini_app_repository.dart';
import 'package:ilink/features/mini_apps/domain/home_screen_shortcut_service.dart';
import 'package:ilink/features/mini_apps/domain/mini_app.dart';
import 'package:ilink/features/mini_apps/domain/mini_app_deep_link.dart';
import 'package:ilink/features/mini_apps/domain/mini_app_icon_resolver.dart';
import 'package:ilink/features/mini_apps/state/home_screen_shortcut_service_provider.dart';
import 'package:ilink/features/mini_apps/state/mini_app_repository_provider.dart';
import 'package:ilink/features/mini_apps/state/mini_app_shortcut_controller.dart';

class _FakeRepository extends MiniAppRepository {
  _FakeRepository(this._catalog);
  final List<MiniApp> _catalog;

  @override
  Future<List<MiniApp>> fetchCatalog({
    required CancelToken cancelToken,
  }) async => _catalog;
  // readCachedCatalog inherits the abstract null-returning default.
}

class _RecordingShortcutService implements HomeScreenShortcutService {
  _RecordingShortcutService({this.onPin});

  final Future<void> Function(PinCall call)? onPin;
  final List<PinCall> calls = [];

  @override
  Future<HomeScreenShortcutStatus> status() async =>
      HomeScreenShortcutStatus.supported;

  @override
  Future<void> pin({
    required String id,
    required String label,
    required String deepLinkUrl,
    required String iconFilePath,
  }) async {
    final call = PinCall(
      id: id,
      label: label,
      deepLinkUrl: deepLinkUrl,
      iconFilePath: iconFilePath,
    );
    calls.add(call);
    if (onPin != null) await onPin!(call);
  }
}

class PinCall {
  const PinCall({
    required this.id,
    required this.label,
    required this.deepLinkUrl,
    required this.iconFilePath,
  });
  final String id;
  final String label;
  final String deepLinkUrl;
  final String iconFilePath;
}

class _OkIconResolver implements MiniAppIconResolver {
  @override
  Future<String> resolve(String icon) async => '/tmp/fake-icon-$icon';
}

class _FailingIconResolver implements MiniAppIconResolver {
  @override
  Future<String> resolve(String icon) async {
    throw IconResolveFailedError(StateError('cdn down'));
  }
}

const _fuelApp = MiniApp(
  id: 'fuel_prices',
  name: {'en': 'Fuel Prices'},
  description: {'en': 'desc'},
  icon: 'https://icons/fuel.png',
  url: 'https://miniapps.ilink.app/fuel/',
  version: '1.0.0',
  minHostVersion: '0.0.1',
  category: 'info',
  bundleUrl:
      'https://miniapps.ilink.app/bundles/fuel_prices/1.0.0/bundle.tar.gz',
  bundleSha256:
      '0000000000000000000000000000000000000000000000000000000000000000',
  safeWhileDriving: true,
);

ProviderContainer _container({
  required List<MiniApp> catalog,
  required HomeScreenShortcutService shortcutService,
  MiniAppIconResolver? iconResolver,
}) {
  return ProviderContainer(
    overrides: [
      miniAppRepositoryProvider.overrideWithValue(_FakeRepository(catalog)),
      homeScreenShortcutServiceProvider.overrideWithValue(shortcutService),
      miniAppIconResolverProvider.overrideWithValue(
        iconResolver ?? _OkIconResolver(),
      ),
    ],
  );
}

void main() {
  setUp(() {
    // MiniAppInstallStorage backs onto SharedPreferences; the catalog
    // controller awaits it before merging install state.
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'pin(success): resolves icon + calls service with app-link URL',
    () async {
      final service = _RecordingShortcutService();
      final c = _container(catalog: const [_fuelApp], shortcutService: service);
      addTearDown(c.dispose);

      final outcome = await c
          .read(miniAppShortcutControllerProvider.notifier)
          .pin('fuel_prices');

      expect(outcome, isA<PinSuccess>());
      expect((outcome as PinSuccess).appName, 'Fuel Prices');
      expect(service.calls, hasLength(1));
      expect(service.calls.first.id, 'fuel_prices');
      expect(service.calls.first.label, 'Fuel Prices');
      expect(
        service.calls.first.deepLinkUrl,
        buildMiniAppDeepLink('fuel_prices'),
      );
      expect(
        service.calls.first.iconFilePath,
        '/tmp/fake-icon-https://icons/fuel.png',
      );
    },
  );

  test(
    'pin(missing id): returns miniAppRemoved without calling service',
    () async {
      final service = _RecordingShortcutService();
      final c = _container(catalog: const [_fuelApp], shortcutService: service);
      addTearDown(c.dispose);

      final outcome = await c
          .read(miniAppShortcutControllerProvider.notifier)
          .pin('never_existed');

      expect(outcome, const PinFailed(PinFailureReason.miniAppRemoved));
      expect(service.calls, isEmpty);
    },
  );

  test('pin(icon resolve fails): pins with empty path → PinPartial', () async {
    final service = _RecordingShortcutService();
    final c = _container(
      catalog: const [_fuelApp],
      shortcutService: service,
      iconResolver: _FailingIconResolver(),
    );
    addTearDown(c.dispose);

    final outcome = await c
        .read(miniAppShortcutControllerProvider.notifier)
        .pin('fuel_prices');

    expect(outcome, isA<PinPartial>());
    expect(service.calls, hasLength(1));
    // Empty string sentinel — Kotlin side reads this as "use launcher icon".
    expect(service.calls.first.iconFilePath, isEmpty);
  });

  test('pin(launcher refused): maps to launcherRefused reason', () async {
    final service = _RecordingShortcutService(
      onPin: (_) async => throw const LauncherRefusedPinError(),
    );
    final c = _container(catalog: const [_fuelApp], shortcutService: service);
    addTearDown(c.dispose);

    final outcome = await c
        .read(miniAppShortcutControllerProvider.notifier)
        .pin('fuel_prices');

    expect(outcome, const PinFailed(PinFailureReason.launcherRefused));
  });

  test(
    'pin(unsupported platform): maps to unsupportedPlatform reason',
    () async {
      final service = _RecordingShortcutService(
        onPin: (_) async => throw const UnsupportedPlatformError(),
      );
      final c = _container(catalog: const [_fuelApp], shortcutService: service);
      addTearDown(c.dispose);

      final outcome = await c
          .read(miniAppShortcutControllerProvider.notifier)
          .pin('fuel_prices');

      expect(outcome, const PinFailed(PinFailureReason.unsupportedPlatform));
    },
  );

  test('pin(channel failure): maps to channelFailure reason', () async {
    final service = _RecordingShortcutService(
      onPin: (_) async => throw const ChannelFailureError('BOOM', 'kaboom'),
    );
    final c = _container(catalog: const [_fuelApp], shortcutService: service);
    addTearDown(c.dispose);

    final outcome = await c
        .read(miniAppShortcutControllerProvider.notifier)
        .pin('fuel_prices');

    expect(outcome, const PinFailed(PinFailureReason.channelFailure));
  });
}

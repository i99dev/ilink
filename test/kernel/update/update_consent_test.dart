import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/app/update/release_source_provider.dart';
import 'package:ilink/app/update/update_controller.dart';
import 'package:ilink/app/update/update_state.dart';
import 'package:ilink/kernel/services/optional_services.dart';
import 'package:ilink/kernel/update/data/release_source.dart';
import 'package:ilink/kernel/update/models/release_manifest.dart';

class _Preferences implements ServicePreferences {
  Set<OptionalService> values = {};
  @override
  Future<Set<OptionalService>> load() async => values;
  @override
  Future<void> save(Set<OptionalService> enabled) async => values = enabled;
}

class _Source implements ReleaseSource {
  int calls = 0;
  Completer<ReleaseManifest?> result = Completer();
  @override
  Future<ReleaseManifest?> latest({required int installedVersionCode}) {
    calls++;
    return result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _Source source;
  setUp(() async {
    source = _Source();
    container = ProviderContainer(
      overrides: [
        servicePreferencesProvider.overrideWithValue(_Preferences()),
        releaseSourceProvider.overrideWithValue(source),
        installedVersionCodeProvider.overrideWith((_) async => 99),
      ],
    );
    await container.read(optionalServicesProvider.future);
    await container.read(updateControllerProvider.future);
  });
  tearDown(() => container.dispose());
  test('fresh install never contacts release source without consent', () async {
    await container.read(updateControllerProvider.notifier).check();
    expect(source.calls, 0);
    expect(container.read(updateControllerProvider).value, isA<UpdateIdle>());
  });
  test(
    'revoking consent discards a late response even after re-enable',
    () async {
      final settings = container.read(optionalServicesProvider.notifier);
      await settings.setEnabled(OptionalService.updates, true);
      final pending = container.read(updateControllerProvider.notifier).check();
      await Future<void>.delayed(Duration.zero);
      expect(source.calls, 1);
      await settings.setEnabled(OptionalService.updates, false);
      await settings.setEnabled(OptionalService.updates, true);
      source.result.complete(
        ReleaseManifest(
          versionCode: 100,
          versionName: '4.0.0',
          apkUrl:
              'https://github.com/i99dev/ilink/releases/download/v4.0.0/ilink.apk',
          sha256: 'a' * 64,
          sizeBytes: 10,
          signerSha256: '',
          forceUpdate: false,
          releasedAt: DateTime.utc(2026),
        ),
      );
      await pending;
      expect(container.read(updateControllerProvider).value, isA<UpdateIdle>());
    },
  );
}

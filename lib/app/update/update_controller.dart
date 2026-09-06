import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:ilink/kernel/update/data/apk_downloader.dart';
import 'package:ilink/kernel/update/data/apk_installer.dart';
import 'package:ilink/kernel/update/data/apk_signer_check.dart';
import 'package:ilink/kernel/services/optional_services.dart';
import 'release_source_provider.dart';
import 'package:ilink/app/update/update_orchestrator.dart' show otaDiagLog;
import 'update_state.dart';

// Resolves the installed versionCode from package_info_plus at startup.
final installedVersionCodeProvider = FutureProvider<int>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return int.tryParse(info.buildNumber) ?? 0;
});

final updateControllerProvider =
    AsyncNotifierProvider<UpdateController, UpdateState>(UpdateController.new);

class UpdateController extends AsyncNotifier<UpdateState> {
  int _generation = 0;

  @override
  Future<UpdateState> build() async {
    ref.listen(optionalServicesProvider, (_, next) {
      if (!(next.value?.contains(OptionalService.updates) ?? false)) defer();
    });
    return const UpdateIdle();
  }

  bool _isCurrent(int generation) =>
      ref.mounted &&
      generation == _generation &&
      ref.read(serviceEnabledProvider(OptionalService.updates));

  Future<void> check() async {
    if (!ref.read(serviceEnabledProvider(OptionalService.updates))) {
      state = const AsyncData(UpdateIdle());
      return;
    }
    final current = state.value;
    if (current is UpdateChecking ||
        current is UpdateDownloading ||
        current is UpdateReadyToInstall ||
        current is UpdateInstalling) {
      return;
    }
    state = const AsyncData(UpdateChecking());
    final generation = ++_generation;
    try {
      final versionCode = await ref.read(installedVersionCodeProvider.future);
      if (!_isCurrent(generation)) return;
      otaDiagLog('check() installed_vc=$versionCode');
      final manifest = await ref
          .read(releaseSourceProvider)
          .latest(installedVersionCode: versionCode);
      if (!_isCurrent(generation)) return;
      if (manifest == null ||
          !ref.read(serviceEnabledProvider(OptionalService.updates))) {
        otaDiagLog('check() manifest=null (204 no-update)');
        state = const AsyncData(UpdateIdle());
        return;
      }
      otaDiagLog(
        'check() manifest=${manifest.versionName} '
        '(vc ${manifest.versionCode}, force=${manifest.forceUpdate})',
      );
      state = AsyncData(UpdateAvailable(manifest));
    } catch (e, st) {
      // Silent on network errors — no prompt, retry next foreground.
      otaDiagLog('check() failed: $e\n$st');
      if (_isCurrent(generation)) state = const AsyncData(UpdateIdle());
    }
  }

  Future<void> download() async {
    if (!ref.read(serviceEnabledProvider(OptionalService.updates))) return;
    final current = state.value;
    if (current is! UpdateAvailable) return;
    final manifest = current.manifest;
    final generation = ++_generation;

    otaDiagLog(
      'download() start vc=${manifest.versionCode} sha=${manifest.sha256.substring(0, 8)} '
      'sizeBytes=${manifest.sizeBytes}',
    );
    state = const AsyncData(UpdateDownloading(0));
    try {
      final file = await ref.read(apkDownloaderProvider).download(manifest, (
        progress,
      ) {
        if (_isCurrent(generation)) {
          state = AsyncData(UpdateDownloading(progress));
        }
      });
      if (!_isCurrent(generation)) return;
      if (!ref.read(serviceEnabledProvider(OptionalService.updates))) {
        state = const AsyncData(UpdateIdle());
        return;
      }
      otaDiagLog('download() apk written: ${file.path}');
      // Verify the signer before handing off to the system installer.
      otaDiagLog('download() verifying signer');
      await ref
          .read(apkSignerCheckProvider)
          .verify(
            file.path,
            expectedPackage: manifest.package,
            expectedVersionCode: manifest.versionCode,
          );
      if (!_isCurrent(generation)) return;
      otaDiagLog('download() signer ok, ready to install');
      state = AsyncData(UpdateReadyToInstall(file, manifest));
    } on OtaShaMismatchException catch (e) {
      if (!_isCurrent(generation)) return;
      otaDiagLog('download() FAILED sha mismatch: $e');
      state = AsyncData(UpdateFailed(e, isFatal: true));
    } on OtaSignerMismatchException catch (e) {
      if (!_isCurrent(generation)) return;
      otaDiagLog('download() FAILED signer mismatch: $e');
      state = AsyncData(UpdateFailed(e, isFatal: true));
    } catch (e, st) {
      if (!_isCurrent(generation)) return;
      otaDiagLog('download() FAILED other: $e\n$st');
      state = AsyncData(UpdateFailed(e));
    }
  }

  Future<void> install() async {
    if (!ref.read(serviceEnabledProvider(OptionalService.updates))) return;
    final current = state.value;
    if (current is! UpdateReadyToInstall) return;
    final generation = ++_generation;
    otaDiagLog('install() start path=${current.file.path}');
    state = const AsyncData(UpdateInstalling());
    try {
      final installed = await PackageInfo.fromPlatform();
      if (!_isCurrent(generation)) return;
      if (!current.manifest.isNewerThan(
        int.tryParse(installed.buildNumber) ?? 0,
      )) {
        state = const AsyncData(UpdateIdle());
        return;
      }
      await ref
          .read(apkDownloaderProvider)
          .verifyFile(current.file, current.manifest);
      if (!_isCurrent(generation)) return;
      await ref
          .read(apkSignerCheckProvider)
          .verify(
            current.file.path,
            expectedPackage: current.manifest.package,
            expectedVersionCode: current.manifest.versionCode,
          );
      if (!_isCurrent(generation)) return;
      await ref.read(apkInstallerProvider).install(current.file);
      otaDiagLog('install() handed to system installer');
      // System installer takes over; state stays Installing until the
      // activity result arrives or the app is killed/relaunched.
    } on OtaInstallDeniedException catch (e) {
      if (!_isCurrent(generation)) return;
      otaDiagLog('install() permission denied: $e');
      // Permission was missing; revert to ready so the user can retry
      // after granting it from the settings page we just opened.
      state = AsyncData(UpdateReadyToInstall(current.file, current.manifest));
    } catch (e, st) {
      if (!_isCurrent(generation)) return;
      otaDiagLog('install() FAILED: $e\n$st');
      state = AsyncData(UpdateFailed(e));
    }
  }

  void defer() {
    _generation++;
    state = const AsyncData(UpdateIdle());
  }
}

import 'dart:io';

import 'package:ilink/kernel/update/models/release_manifest.dart';

sealed class UpdateState {
  const UpdateState();
}

class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

class UpdateChecking extends UpdateState {
  const UpdateChecking();
}

class UpdateAvailable extends UpdateState {
  const UpdateAvailable(this.manifest);
  final ReleaseManifest manifest;
}

class UpdateDownloading extends UpdateState {
  const UpdateDownloading(this.progress);
  final double progress;
}

class UpdateReadyToInstall extends UpdateState {
  const UpdateReadyToInstall(this.file, this.manifest);
  final File file;
  final ReleaseManifest manifest;
}

class UpdateInstalling extends UpdateState {
  const UpdateInstalling();
}

class UpdateFailed extends UpdateState {
  const UpdateFailed(this.reason, {this.isFatal = false});
  final Object reason;
  final bool isFatal;
}

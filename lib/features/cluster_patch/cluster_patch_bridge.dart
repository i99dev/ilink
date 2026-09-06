import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Dart side of the `ilink/cluster_patch` MethodChannel — the remediation
/// half of the two-tier cluster cast. Mirrors the Kotlin
/// `ClusterPatchPlugin`. Only invoked after a native cluster cast was
/// refused and the user consented.

/// What a package's patch eligibility is.
enum PatchCapability {
  /// Eligible — a normal third-party app we can re-sign + replace.
  amber,

  /// Already patched at its current version — nothing to do.
  green,

  /// Blocked — a system or our own app; re-signing would brick or is moot.
  red,

  /// Probe failed / unknown.
  unknown,
}

PatchCapability _capabilityOf(String? raw) => switch (raw) {
  'AMBER' => PatchCapability.amber,
  'GREEN' => PatchCapability.green,
  'RED' => PatchCapability.red,
  _ => PatchCapability.unknown,
};

class ProbeResult {
  const ProbeResult({
    required this.capability,
    required this.alreadyPatched,
    this.reason,
  });

  final PatchCapability capability;
  final bool alreadyPatched;
  final String? reason;

  /// Only AMBER apps are worth offering a patch for.
  bool get eligible => capability == PatchCapability.amber;
}

enum PatchStatus { patched, alreadyPatched, failed }

class PatchOutcome {
  const PatchOutcome({required this.status, this.stage, this.detail});

  final PatchStatus status;

  /// Failure stage ∈ {resolve, patch, stage, create, write, commit}.
  final String? stage;
  final String? detail;

  bool get ok =>
      status == PatchStatus.patched || status == PatchStatus.alreadyPatched;
}

enum UnpatchStatus {
  /// The backed-up original APK was reinstalled.
  restored,

  /// The patched app was uninstalled, but there was no backup to restore —
  /// the user must reinstall the original from the store.
  removed,
  failed,
}

class UnpatchOutcome {
  const UnpatchOutcome({required this.status, this.detail});
  final UnpatchStatus status;
  final String? detail;
  bool get ok => status != UnpatchStatus.failed;
}

abstract class ClusterPatchBridge {
  Future<ProbeResult> probe(String packageName);
  Future<PatchOutcome> patch(String packageName);
  Future<UnpatchOutcome> unpatch(String packageName);

  /// Package names we've patched (from the on-device registry) — drives the
  /// "Patched" badges in the Cluster-apps list.
  Future<Set<String>> patchedPackages();
}

class PlatformClusterPatchBridge implements ClusterPatchBridge {
  PlatformClusterPatchBridge({MethodChannel? channel})
    : _ch = channel ?? const MethodChannel('ilink/cluster_patch');

  final MethodChannel _ch;

  @override
  Future<ProbeResult> probe(String packageName) async {
    final raw =
        await _ch.invokeMapMethod<String, Object?>('probe', {
          'packageName': packageName,
        }) ??
        const <String, Object?>{};
    return ProbeResult(
      capability: _capabilityOf(raw['capability'] as String?),
      alreadyPatched: raw['alreadyPatched'] == true,
      reason: raw['reason'] as String?,
    );
  }

  @override
  Future<PatchOutcome> patch(String packageName) async {
    final raw =
        await _ch.invokeMapMethod<String, Object?>('patch', {
          'packageName': packageName,
        }) ??
        const <String, Object?>{};
    final status = switch (raw['outcome'] as String?) {
      'patched' => PatchStatus.patched,
      'already_patched' => PatchStatus.alreadyPatched,
      _ => PatchStatus.failed,
    };
    return PatchOutcome(
      status: status,
      stage: raw['stage'] as String?,
      detail: raw['detail'] as String?,
    );
  }

  @override
  Future<UnpatchOutcome> unpatch(String packageName) async {
    final raw =
        await _ch.invokeMapMethod<String, Object?>('unpatch', {
          'packageName': packageName,
        }) ??
        const <String, Object?>{};
    final status = switch (raw['result'] as String?) {
      'restored' => UnpatchStatus.restored,
      'removed' => UnpatchStatus.removed,
      _ => UnpatchStatus.failed,
    };
    return UnpatchOutcome(status: status, detail: raw['detail'] as String?);
  }

  @override
  Future<Set<String>> patchedPackages() async {
    final raw =
        await _ch.invokeMapMethod<String, Object?>('patchedList') ??
        const <String, Object?>{};
    final list = (raw['packages'] as List?)?.cast<String>() ?? const <String>[];
    return list.toSet();
  }
}

final clusterPatchBridgeProvider = Provider<ClusterPatchBridge>(
  (ref) => PlatformClusterPatchBridge(),
);

/// The set of packages we've patched. Watched by the Cluster-apps list to
/// show a "Patched" badge; invalidate it after a patch/unpatch to refresh.
final patchedPackagesProvider = FutureProvider<Set<String>>(
  (ref) => ref.read(clusterPatchBridgeProvider).patchedPackages(),
);

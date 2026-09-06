import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../kernel/services/optional_services.dart';

import 'ondevice_voice_bridge.dart';
import 'voice_model_catalog.dart';

/// Lifecycle of the on-demand Arabic Moonshine engine bundle (the ONNX model +
/// tokens + the ~31 MB sherpa-onnx / ONNX Runtime `.so` stripped from the
/// release APK). Drives the Settings "Arabic Speech Recognition Engine" card.
enum MoonshineEngineStatus {
  /// Not on disk — show a Download button + the size.
  absent,

  /// Downloading + unpacking — show a progress bar.
  downloading,

  /// On disk + usable — show "Active" + a Delete button.
  present,

  /// Last download/delete failed — show "failed, tap to retry".
  error,
}

/// Snapshot the Settings card watches.
@immutable
class MoonshineEngineState {
  const MoonshineEngineState(this.status, {this.progress, this.error});

  final MoonshineEngineStatus status;

  /// 0..1 while [MoonshineEngineStatus.downloading]; null = indeterminate
  /// (server didn't report Content-Length) or not downloading.
  final double? progress;

  /// Failure reason when [status] is [MoonshineEngineStatus.error].
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is MoonshineEngineState &&
      other.status == status &&
      other.progress == progress &&
      other.error == error;

  @override
  int get hashCode => Object.hash(status, progress, error);
}

/// Manages the Arabic Moonshine bundle independently of the live voice
/// detector ([OnDeviceVoiceController], which auto-provisions it on `arm()`).
///
/// This exists so the driver can EXPLICITLY download or delete the ~141 MB
/// Arabic engine from Settings — reclaiming the disk when Arabic voice isn't
/// wanted — without arming the detector. It owns its own (stateless) bridge
/// instance; the native channel is a singleton, so this never conflicts with
/// the detector's instance.
///
/// Deleting while Arabic voice is actively armed is harmless: the running
/// engine's `.so` are already mmap'd, so it keeps working until the next
/// re-arm, which re-provisions on demand.
class MoonshineEngineManager extends Notifier<MoonshineEngineState> {
  PlatformOnDeviceRecognizer? _recognizer;
  StreamSubscription<({int received, int total})>? _progressSub;

  PlatformOnDeviceRecognizer get _bridge =>
      _recognizer ??= PlatformOnDeviceRecognizer();

  /// The single catalog fallback (Arabic Moonshine). Null if the catalog
  /// declares none — the card then renders nothing.
  static VoiceModelFallback? get fallback {
    for (final e in voiceModelCatalog) {
      final fb = e.fallback;
      if (fb != null && fb.engine == VoiceEngine.moonshine) return fb;
    }
    return null;
  }

  @override
  MoonshineEngineState build() {
    ref.listen<bool>(serviceEnabledProvider(OptionalService.downloads), (
      _,
      enabled,
    ) {
      unawaited(
        _bridge.setModelDownloadsEnabled(enabled).catchError((Object _) {}),
      );
    }, fireImmediately: true);
    ref.onDispose(() => unawaited(_progressSub?.cancel()));
    // Resolve real on-disk state asynchronously; start optimistically absent.
    // Deferred to a microtask: `refresh` is async but runs synchronously up to
    // its first `await`, and its guard reads `state` — which Riverpod has not
    // initialised until this `build` returns. Calling it directly threw
    // "Tried to read the state of an uninitialized provider" every time the
    // tile was first built.
    unawaited(Future.microtask(refresh));
    return const MoonshineEngineState(MoonshineEngineStatus.absent);
  }

  /// Re-read on-disk presence (cheap native stat). No-op mid-download.
  Future<void> refresh() async {
    if (state.status == MoonshineEngineStatus.downloading) return;
    final fb = fallback;
    if (fb == null) return;
    final present = await _bridge.fallbackModelPresent(version: fb.version);
    state = MoonshineEngineState(
      present ? MoonshineEngineStatus.present : MoonshineEngineStatus.absent,
    );
  }

  /// Download + unpack the Arabic bundle (model + `.so`) with live progress.
  /// Idempotent: instant if already present. Safe to call from a button tap.
  Future<void> download() async {
    final fb = fallback;
    if (fb == null || state.status == MoonshineEngineStatus.downloading) return;

    state = const MoonshineEngineState(
      MoonshineEngineStatus.downloading,
      progress: null,
    );
    await _progressSub?.cancel();
    _progressSub = _bridge.provisionProgress.listen((p) {
      if (state.status != MoonshineEngineStatus.downloading) return;
      final pct = p.total > 0 ? (p.received / p.total).clamp(0.0, 1.0) : null;
      state = MoonshineEngineState(
        MoonshineEngineStatus.downloading,
        progress: pct,
      );
    });

    try {
      final ok = await _bridge.provisionFallback(
        url: fb.url,
        version: fb.version,
        allowNetwork: ref.read(
          serviceEnabledProvider(OptionalService.downloads),
        ),
      );
      if (!ref.mounted) return;
      state = ok
          ? const MoonshineEngineState(MoonshineEngineStatus.present)
          : MoonshineEngineState(
              MoonshineEngineStatus.error,
              error: ref.read(serviceEnabledProvider(OptionalService.downloads))
                  ? 'download_failed'
                  : 'local_model_missing',
            );
    } catch (e) {
      state = MoonshineEngineState(
        MoonshineEngineStatus.error,
        error: e.toString(),
      );
    } finally {
      await _progressSub?.cancel();
      _progressSub = null;
    }
  }

  /// Delete the bundle, reclaiming ~141 MB. Re-selecting Arabic voice (or
  /// tapping Download) re-provisions it.
  Future<void> delete() async {
    final fb = fallback;
    if (fb == null || state.status == MoonshineEngineStatus.downloading) return;
    final ok = await _bridge.deleteFallback(version: fb.version);
    state = ok
        ? const MoonshineEngineState(MoonshineEngineStatus.absent)
        : const MoonshineEngineState(
            MoonshineEngineStatus.error,
            error: 'delete_failed',
          );
  }
}

final moonshineEngineManagerProvider =
    NotifierProvider<MoonshineEngineManager, MoonshineEngineState>(
      MoonshineEngineManager.new,
    );

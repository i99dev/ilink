import 'dart:async';

import 'package:flutter/services.dart';

import 'on_device_recognizer.dart';
import 'voice_grammar.dart';

/// Platform implementation of the [OnDeviceRecognizer] seam — bridges the
/// Phase-1a brain (the registry-derived [VoiceGrammar]) to the native Vosk
/// engine over the `ilink/ondevice_voice` channel (see
/// `OnDeviceVoiceChannel.kt`).
///
/// The model path is resolved natively ([VoskModelStore]); Dart only sends
/// the grammar JSON, so provisioning/CDN concerns never leak into Dart.
class PlatformOnDeviceRecognizer implements OnDeviceRecognizer {
  PlatformOnDeviceRecognizer({
    MethodChannel? method,
    EventChannel? events,
    EventChannel? provisionEvents,
    EventChannel? utteranceEvents,
  }) : _method = method ?? const MethodChannel('ilink/ondevice_voice'),
       _events = events ?? const EventChannel('ilink/ondevice_voice/events'),
       _provisionEvents =
           provisionEvents ??
           const EventChannel('ilink/ondevice_voice/provision'),
       _utteranceEvents =
           utteranceEvents ??
           const EventChannel('ilink/ondevice_voice/utterance');

  final MethodChannel _method;
  final EventChannel _events;
  final EventChannel _provisionEvents;
  final EventChannel _utteranceEvents;
  Stream<OnDeviceResult>? _results;
  Stream<({int received, int total})>? _provisionProgress;
  Stream<Uint8List>? _utteranceMisses;

  /// Live model-download progress (bytes). `total` is 0 when the server
  /// didn't report Content-Length (→ show an indeterminate bar). Emits
  /// only during an active `provisionModel` download.
  Stream<({int received, int total})> get provisionProgress =>
      _provisionProgress ??= _provisionEvents.receiveBroadcastStream().map((e) {
        final m = (e as Map).cast<String, Object?>();
        return (
          received: (m['received'] as num?)?.toInt() ?? 0,
          total: (m['total'] as num?)?.toInt() ?? 0,
        );
      });

  Future<bool> modelPresent({required String version}) async =>
      (await _method.invokeMethod<bool>('modelPresent', {
        'version': version,
      })) ??
      false;

  /// Download + unpack the [version]'s Kaldi model from [url] (a zip) into its
  /// own per-version dir, idempotent. The fleet path (CDN); dev uses adb-push.
  /// Returns true iff a usable model for [version] is present afterward —
  /// instant when already cached (switching language back never re-downloads).
  Future<bool> provisionModel({
    required String url,
    required String version,
    bool allowNetwork = false,
  }) async {
    final raw = await _method.invokeMapMethod<String, Object?>(
      'provisionModel',
      {'url': url, 'version': version, 'allowNetwork': allowNetwork},
    );
    return raw?['ok'] == true;
  }

  // ---- Moonshine fallback (Arabic second tier) ----

  /// Revokes native requests immediately; local models remain available.
  Future<void> setModelDownloadsEnabled(bool enabled) async {
    await _method.invokeMethod<bool>('setModelDownloadsEnabled', {
      'enabled': enabled,
    });
  }

  /// True when the [version]'s Moonshine fallback bundle (.ort + tokens) is
  /// provisioned. Checked separately from the Vosk primary.
  Future<bool> fallbackModelPresent({required String version}) async =>
      (await _method.invokeMethod<bool>('fallbackModelPresent', {
        'version': version,
      })) ??
      false;

  /// Download + unpack the [version]'s Moonshine fallback zip from [url].
  /// Same resilient download/progress as [provisionModel]; ONNX presence check.
  Future<bool> provisionFallback({
    required String url,
    required String version,
    bool allowNetwork = false,
  }) async {
    final raw = await _method.invokeMapMethod<String, Object?>(
      'provisionFallback',
      {'url': url, 'version': version, 'allowNetwork': allowNetwork},
    );
    return raw?['ok'] == true;
  }

  /// Absolute dir of the provisioned fallback model for [version], or null.
  /// The Dart [MoonshineFallbackEngine] loads the .ort files from here.
  Future<String?> fallbackModelPath({required String version}) =>
      _method.invokeMethod<String>('fallbackModelPath', {'version': version});

  /// Delete the [version]'s Moonshine fallback bundle (ONNX model + tokens +
  /// the ~31 MB of `.so` runtime libs), reclaiming the disk. Returns true if
  /// nothing remains on disk afterward. Used by Settings to let the driver free
  /// the Arabic engine; re-selecting Arabic re-provisions it on demand.
  Future<bool> deleteFallback({required String version}) async {
    final raw = await _method.invokeMapMethod<String, Object?>(
      'deleteFallback',
      {'version': version},
    );
    return raw?['ok'] == true;
  }

  /// Arm/disarm the native PCM-buffering needed for the fallback. When false
  /// the capture loop never buffers (zero overhead for non-Arabic languages).
  Future<void> setFallbackEnabled(bool enabled) =>
      _method.invokeMethod('setFallbackEnabled', {'enabled': enabled});

  /// Raw 16-bit LE PCM of each utterance Vosk rejected (`[unk]`) — only while
  /// fallback is enabled. Feed each buffer to [MoonshineFallbackEngine].
  Stream<Uint8List> get utteranceMisses =>
      _utteranceMisses ??= _utteranceEvents.receiveBroadcastStream().map(
        (e) =>
            e is Uint8List ? e : Uint8List.fromList(List<int>.from(e as List)),
      );

  @override
  Future<void> applyGrammar(
    VoiceGrammar grammar, {
    required String version,
  }) async {
    final raw = await _method.invokeMapMethod<String, Object?>('applyGrammar', {
      'grammar': grammar.toVoskGrammarJson(),
      'version': version,
    });
    if (raw?['ok'] != true) {
      throw OnDeviceVoiceException(
        raw?['error']?.toString() ?? 'applyGrammar failed',
      );
    }
  }

  @override
  Stream<OnDeviceResult> get results =>
      _results ??= _events.receiveBroadcastStream().map((e) {
        final m = (e as Map).cast<String, Object?>();
        return OnDeviceResult(
          text: m['text'] as String? ?? '',
          isFinal: m['isFinal'] as bool? ?? false,
        );
      });

  @override
  Future<void> start() => _method.invokeMethod('start');

  @override
  Future<void> stop() => _method.invokeMethod('stop');

  @override
  Future<void> dispose() => _method.invokeMethod('dispose');
}

class OnDeviceVoiceException implements Exception {
  OnDeviceVoiceException(this.message);
  final String message;
  @override
  String toString() => 'OnDeviceVoiceException: $message';
}

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// The Arabic second-tier recognizer: Moonshine (sherpa-onnx), run ONLY on a
/// Vosk `[unk]` miss. Vosk owns the mic and segments utterances; this engine
/// is handed the raw PCM of one rejected utterance and freely transcribes it
/// (no grammar). The transcript then goes through the SAME [LocalIntentMatcher]
/// the Vosk path uses, so dispatch/gate/audit are unchanged.
///
/// Non-streaming + offline. Model files come from the provisioned fallback
/// bundle (`encoder_model.ort` + `decoder_model_merged.ort` + `tokens.txt`),
/// whose dir the native side resolves ([MoonshineModelStore]). The bundled
/// `silero_vad.onnx` is unused here — Vosk already did the segmentation.
///
/// Load failures degrade gracefully: [load] returns null and the caller stays
/// Vosk-only (a missing fallback must never break the primary fast-path).
///
/// Native libs (`.so`): the sherpa-onnx / ONNX Runtime libs (~31 MB) are NOT in
/// the release APK — they ride inside the same on-demand Moonshine bundle as the
/// model and unpack into [load]'s `dir`. [load] pre-loads them by absolute path
/// from `dir` in DT_NEEDED order (`libonnxruntime.so` → `libsherpa-onnx-cxx-api.so`
/// → `libsherpa-onnx-c-api.so`; the linker resolves a dependency against the
/// already-loaded copies by soname). If `dir` has no `.so` — debug builds keep
/// them in-APK, and a dev may `adb push` only the model — it falls back to the
/// default package loader, which finds the APK-bundled libs.
class MoonshineFallbackEngine {
  MoonshineFallbackEngine._(this._recognizer);

  final sherpa.OfflineRecognizer _recognizer;

  static bool _bindingsReady = false;

  /// Native libs pre-loaded from the model dir, in dependency order, so the
  /// linker resolves `libsherpa-onnx-c-api.so`'s DT_NEEDED entries against the
  /// downloaded copies rather than searching the (release-stripped) APK. The
  /// dependent (`libsherpa-onnx-c-api.so`) MUST be last — it needs the other
  /// two loaded first. Public so the contract is unit-testable.
  static const List<String> orderedNativeLibs = <String>[
    'libonnxruntime.so',
    'libsherpa-onnx-cxx-api.so',
    'libsherpa-onnx-c-api.so',
  ];

  /// Build an engine from a provisioned Moonshine model [dir] (absolute path
  /// to the folder holding the .ort files + tokens — and, in release, the
  /// `.so` runtime libs). Returns null if the native bindings or model can't
  /// be loaded.
  static MoonshineFallbackEngine? load({
    required String dir,
    int numThreads = 2,
  }) {
    try {
      if (!_bindingsReady) {
        _initBindingsFrom(dir);
        _bindingsReady = true;
      }
      final config = sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          moonshine: sherpa.OfflineMoonshineModelConfig(
            encoder: '$dir/encoder_model.ort',
            mergedDecoder: '$dir/decoder_model_merged.ort',
          ),
          tokens: '$dir/tokens.txt',
          numThreads: numThreads,
          debug: false,
        ),
      );
      return MoonshineFallbackEngine._(sherpa.OfflineRecognizer(config));
    } catch (_) {
      return null;
    }
  }

  /// Initialize the sherpa-onnx FFI bindings, loading the native `.so` from
  /// [dir] when the libs are present there (release: shipped in the on-demand
  /// bundle), else from the default location (debug/dev: bundled in the APK).
  ///
  /// When loading from [dir], the libs are opened in dependency order so the
  /// dynamic linker can satisfy `libsherpa-onnx-c-api.so`'s DT_NEEDED entries
  /// (`libonnxruntime.so`, `libsherpa-onnx-cxx-api.so`) from the already-loaded
  /// copies — `dlopen` of an absolute path does NOT add that file's directory
  /// to the search path for its own dependencies, so they must be pre-loaded.
  static void _initBindingsFrom(String dir) {
    final fromDir = File('$dir/${orderedNativeLibs.last}').existsSync();
    if (fromDir) {
      // Pre-load deps; the last entry (c-api) is what initBindings opens.
      for (final lib in orderedNativeLibs) {
        DynamicLibrary.open('$dir/$lib');
      }
      sherpa.initBindings(dir);
    } else {
      sherpa.initBindings();
    }
  }

  /// Transcribe one utterance of 16 kHz mono 16-bit little-endian PCM.
  /// Returns the raw transcript (may be empty); matching/normalization is the
  /// caller's job (via the shared `normalizePhrase` + `LocalIntentMatcher`).
  String transcribe(Uint8List pcm16le) {
    final samples = pcm16ToFloat32(pcm16le);
    if (samples.isEmpty) return '';
    final stream = _recognizer.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      _recognizer.decode(stream);
      return _recognizer.getResult(stream).text.trim();
    } finally {
      stream.free();
    }
  }

  void dispose() => _recognizer.free();
}

/// Convert little-endian 16-bit PCM bytes to normalized Float32 samples in
/// [-1, 1). Pure + tiny, so it's unit-testable without the native engine.
Float32List pcm16ToFloat32(Uint8List pcm16le) {
  final count = pcm16le.lengthInBytes ~/ 2;
  final out = Float32List(count);
  final bd = ByteData.sublistView(pcm16le);
  for (var i = 0; i < count; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

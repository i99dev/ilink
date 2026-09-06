import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/voice/ondevice/moonshine_engine_manager.dart';
import 'package:ilink/features/voice/ondevice/moonshine_fallback_engine.dart';
import 'package:ilink/features/voice/ondevice/voice_grammar.dart';
import 'package:ilink/features/voice/ondevice/voice_model_catalog.dart';

void main() {
  group('native lib load order (DT_NEEDED chain)', () {
    test('the three sherpa/onnx .so are listed deps-first', () {
      const libs = MoonshineFallbackEngine.orderedNativeLibs;
      expect(libs, hasLength(3));
      // onnxruntime is the base dependency → must load first.
      expect(libs.first, 'libonnxruntime.so');
      // c-api links against the other two → must load LAST so its DT_NEEDED
      // entries resolve against the already-loaded copies.
      expect(libs.last, 'libsherpa-onnx-c-api.so');
      expect(libs, contains('libsherpa-onnx-cxx-api.so'));
    });
  });

  group('MoonshineEngineManager.fallback', () {
    test('resolves the single Arabic Moonshine bundle from the catalog', () {
      final fb = MoonshineEngineManager.fallback;
      expect(fb, isNotNull);
      expect(fb!.engine, VoiceEngine.moonshine);
      // Bundle now carries the .so → the `-libs` artifact + ~141 MB size.
      expect(fb.version, 'ar-moonshine-libs-2026-06-26');
      expect(fb.sizeMb, greaterThan(120));
    });
  });

  group('pcm16ToFloat32', () {
    test('decodes little-endian int16 to [-1,1)', () {
      // 0, +1, -1, max, min as LE int16.
      final bytes = Uint8List.fromList([
        0x00, 0x00, // 0
        0x01, 0x00, // +1
        0xFF, 0xFF, // -1
        0xFF, 0x7F, // 32767
        0x00, 0x80, // -32768
      ]);
      final f = pcm16ToFloat32(bytes);
      expect(f.length, 5);
      expect(f[0], 0.0);
      expect(f[1], closeTo(1 / 32768, 1e-9));
      expect(f[2], closeTo(-1 / 32768, 1e-9));
      expect(f[3], closeTo(32767 / 32768, 1e-6));
      expect(f[4], -1.0);
    });

    test('odd trailing byte is ignored (sample-aligned)', () {
      expect(pcm16ToFloat32(Uint8List.fromList([0x00])).length, 0);
      expect(pcm16ToFloat32(Uint8List.fromList([0x00, 0x00, 0x11])).length, 1);
    });
  });

  group('Arabic normalize folding (Moonshine ↔ Vosk parity)', () {
    test('diacritics + tatweel are dropped', () {
      // Fully-voweled Moonshine-style output folds to the bare phrase.
      expect(normalizePhrase('النَّافِذَةَ'), normalizePhrase('النافذة'));
      expect(normalizePhrase('اطفـئ'), normalizePhrase('اطفئ'));
    });

    test('alef/ya/hamza-seat variants unify', () {
      expect(normalizePhrase('إفتح'), normalizePhrase('افتح'));
      expect(normalizePhrase('أقصى'), normalizePhrase('اقصي'));
      expect(normalizePhrase('اطفئ'), normalizePhrase('اطفي'));
    });

    test('ASCII text is unaffected by folding', () {
      expect(normalizePhrase('Lock The Doors!'), 'lock the doors');
    });
  });
}

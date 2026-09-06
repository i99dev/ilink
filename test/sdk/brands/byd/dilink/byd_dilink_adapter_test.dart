/// Readiness matrix: every supported [DilinkVersion] must produce a
/// valid [BydDilinkAdapter] with self-consistent policy flags.
///
/// This is the CI gate that catches drift when a new DiLink ROM
/// adapter ships incomplete — e.g. someone adds a `dilink_5_2`
/// enum entry but forgets to register a concrete adapter. The
/// matrix loops over every enum value and fails specifically at
/// the version that broke.
///
/// See `docs/sdk/identity.md` for the contract every adapter must
/// satisfy.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/sdk/brands/byd/dilink/dilink.dart';

void main() {
  setUpAll(() {
    // The adapter registry initialises lazily on the first
    // BydClient construct. Tests don't construct BydClient, so
    // force registration up front.
    ensureBydDilinkAdaptersRegistered();
  });

  group('BydDilinkAdapter readiness matrix', () {
    for (final v in DilinkVersion.values) {
      test('${v.wire}: registered + consistent', () {
        final adapter = BydDilinkAdapter.forTesting(v);

        // 1. Self-identification
        expect(
          adapter.version,
          v,
          reason: 'adapter must report the version it was registered as',
        );

        // 2. Wire round-trip
        expect(
          DilinkVersion.fromWire(v.wire),
          v,
          reason: 'wire string must round-trip back to enum',
        );

        // 3. Asset bundle dir is either null (use shared default) or
        //    a snake_case identifier safe for filenames.
        final bundle = adapter.assetBundleDir;
        if (bundle != null) {
          expect(
            RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(bundle),
            isTrue,
            reason: 'asset bundle dir must be snake_case (got $bundle)',
          );
        }

        // 4. Boolean flags must be set (not null — they're non-nullable).
        // This is a static-type guarantee but a runtime check guards
        // against future API drift if the bools become nullable.
        expect(adapter.pushRequiresAppContext, anyOf(isTrue, isFalse));
        expect(adapter.clusterPixelSignatureGated, anyOf(isTrue, isFalse));
      });
    }

    test('detect() returns a known version (no nulls)', () {
      ensureBydDilinkAdaptersRegistered();
      final adapter = BydDilinkAdapter.detect();
      expect(DilinkVersion.values, contains(adapter.version));
    });

    test('detect(force: ...) honours the override for tests', () {
      ensureBydDilinkAdaptersRegistered();
      for (final v in DilinkVersion.values) {
        final adapter = BydDilinkAdapter.detect(force: v);
        expect(adapter.version, v);
      }
    });
  });

  group('Version-specific policy contracts', () {
    setUp(ensureBydDilinkAdaptersRegistered);

    test('DiLink 5.0 — push reaches both contexts; no signature gate', () {
      final a = BydDilinkAdapter.forTesting(DilinkVersion.dilink_5_0);
      expect(a.pushRequiresAppContext, isFalse);
      expect(a.clusterPixelSignatureGated, isFalse);
      expect(a.assetBundleDir, 'dilink_5_0');
    });

    test('DiLink 5.1 — App-context-only push; no signature gate', () {
      final a = BydDilinkAdapter.forTesting(DilinkVersion.dilink_5_1);
      expect(a.pushRequiresAppContext, isTrue);
      expect(a.clusterPixelSignatureGated, isFalse);
    });

    test('DiLink 8.x — App-context-only push; cluster pixel gated', () {
      final a = BydDilinkAdapter.forTesting(DilinkVersion.dilink_8_x);
      expect(a.pushRequiresAppContext, isTrue);
      expect(a.clusterPixelSignatureGated, isTrue);
    });

    test('unknown — conservative defaults (strict)', () {
      final a = BydDilinkAdapter.forTesting(DilinkVersion.unknown);
      // Conservative: assume strict, fallback safely.
      expect(a.pushRequiresAppContext, isTrue);
      expect(a.clusterPixelSignatureGated, isTrue);
    });
  });
}

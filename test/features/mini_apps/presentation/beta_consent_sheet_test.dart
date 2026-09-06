/// Tests for [BetaConsentStorage] and the consent-gate logic exercised by
/// [showBetaConsentIfNeeded]:
///   - Sheet shows on first launch of a beta app.
///   - Sheet does NOT show on second launch with same (userId, appId, version).
///   - Sheet shows again when the version bumps.
///   - Sheet shows again when the userId changes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/mini_apps/data/beta_consent_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  BetaConsentStorage newStorage() =>
      BetaConsentStorage(SharedPreferences.getInstance);

  group('BetaConsentStorage', () {
    test('hasConsented returns false before any consent is recorded', () async {
      final storage = newStorage();
      expect(
        await storage.hasConsented(
          userId: 'user-1',
          appId: 'app-1',
          version: '1.0.0',
        ),
        isFalse,
      );
    });

    test(
      'hasConsented returns true after recordConsent for same triple',
      () async {
        final storage = newStorage();
        await storage.recordConsent(
          userId: 'user-1',
          appId: 'app-1',
          version: '1.0.0',
        );
        expect(
          await storage.hasConsented(
            userId: 'user-1',
            appId: 'app-1',
            version: '1.0.0',
          ),
          isTrue,
        );
      },
    );

    // ── Version bump ──────────────────────────────────────────────────────

    test('hasConsented returns false after version bumps', () async {
      final storage = newStorage();
      // User consented for v1.0.0 …
      await storage.recordConsent(
        userId: 'user-1',
        appId: 'app-1',
        version: '1.0.0',
      );
      // … developer releases v1.1.0 beta — consent must be re-obtained.
      expect(
        await storage.hasConsented(
          userId: 'user-1',
          appId: 'app-1',
          version: '1.1.0',
        ),
        isFalse,
      );
    });

    // ── User change ───────────────────────────────────────────────────────

    test('hasConsented returns false for a different userId', () async {
      final storage = newStorage();
      await storage.recordConsent(
        userId: 'user-1',
        appId: 'app-1',
        version: '1.0.0',
      );
      // Different user on the same device must see the sheet.
      expect(
        await storage.hasConsented(
          userId: 'user-2',
          appId: 'app-1',
          version: '1.0.0',
        ),
        isFalse,
      );
    });

    // ── App isolation ─────────────────────────────────────────────────────

    test('consent for one app does not bleed to another app', () async {
      final storage = newStorage();
      await storage.recordConsent(
        userId: 'user-1',
        appId: 'app-1',
        version: '1.0.0',
      );
      expect(
        await storage.hasConsented(
          userId: 'user-1',
          appId: 'app-2',
          version: '1.0.0',
        ),
        isFalse,
      );
    });

    // ── Multiple consents ─────────────────────────────────────────────────

    test('multiple consents stored independently', () async {
      final storage = newStorage();
      await storage.recordConsent(
        userId: 'user-1',
        appId: 'app-1',
        version: '1.0.0',
      );
      await storage.recordConsent(
        userId: 'user-1',
        appId: 'app-2',
        version: '2.0.0',
      );
      await storage.recordConsent(
        userId: 'user-2',
        appId: 'app-1',
        version: '1.0.0',
      );

      expect(
        await storage.hasConsented(
          userId: 'user-1',
          appId: 'app-1',
          version: '1.0.0',
        ),
        isTrue,
      );
      expect(
        await storage.hasConsented(
          userId: 'user-1',
          appId: 'app-2',
          version: '2.0.0',
        ),
        isTrue,
      );
      expect(
        await storage.hasConsented(
          userId: 'user-2',
          appId: 'app-1',
          version: '1.0.0',
        ),
        isTrue,
      );
      // Different version for user-2/app-1 is still false.
      expect(
        await storage.hasConsented(
          userId: 'user-2',
          appId: 'app-1',
          version: '2.0.0',
        ),
        isFalse,
      );
    });

    // ── Persistence ───────────────────────────────────────────────────────

    test('consent survives a process restart (new storage instance)', () async {
      // Record via one instance …
      await newStorage().recordConsent(
        userId: 'user-1',
        appId: 'app-1',
        version: '1.0.0',
      );
      // … read via a fresh instance that rebuilds from SharedPreferences.
      expect(
        await newStorage().hasConsented(
          userId: 'user-1',
          appId: 'app-1',
          version: '1.0.0',
        ),
        isTrue,
      );
    });

    // ── Clear ─────────────────────────────────────────────────────────────

    test('clear wipes all stored consents', () async {
      final storage = newStorage();
      await storage.recordConsent(
        userId: 'user-1',
        appId: 'app-1',
        version: '1.0.0',
      );
      await storage.clear();
      expect(
        await storage.hasConsented(
          userId: 'user-1',
          appId: 'app-1',
          version: '1.0.0',
        ),
        isFalse,
      );
    });

    // ── Legacy format read-compat ─────────────────────────────────────────

    test('reads pre-migration Map<String, bool> blob', () async {
      // Older clients persisted consents as a JSON object with `true`
      // values. New code must still recognise those triples on read so
      // an upgrade doesn't re-prompt.
      SharedPreferences.setMockInitialValues({
        'mini_apps.beta_consent':
            '{"user-1/app-1/1.0.0": true, "user-1/app-2/2.0.0": true}',
      });
      final storage = newStorage();

      expect(
        await storage.hasConsented(
          userId: 'user-1',
          appId: 'app-1',
          version: '1.0.0',
        ),
        isTrue,
      );
      expect(
        await storage.hasConsented(
          userId: 'user-1',
          appId: 'app-2',
          version: '2.0.0',
        ),
        isTrue,
      );
    });

    test('first write after legacy read upgrades blob to list shape', () async {
      SharedPreferences.setMockInitialValues({
        'mini_apps.beta_consent': '{"user-1/app-1/1.0.0": true}',
      });
      final storage = newStorage();
      // Trigger a write by recording a new consent.
      await storage.recordConsent(
        userId: 'user-1',
        appId: 'app-2',
        version: '2.0.0',
      );

      // Verify on-disk blob is now a JSON list (not a map).
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('mini_apps.beta_consent')!;
      expect(
        raw.startsWith('['),
        isTrue,
        reason: 'expected list shape, got: $raw',
      );
      // Both the legacy entry and the new entry must survive the upgrade.
      expect(raw, contains('user-1/app-1/1.0.0'));
      expect(raw, contains('user-1/app-2/2.0.0'));
    });

    // ── In-memory cache ───────────────────────────────────────────────────

    test('subsequent reads skip SharedPreferences after first load', () async {
      final storage = newStorage();
      // Prime the cache with an existing consent.
      await storage.recordConsent(
        userId: 'user-1',
        appId: 'app-1',
        version: '1.0.0',
      );
      // Mutate SharedPreferences directly behind the storage's back.
      // Since the in-memory cache holds the truth, the next read must
      // still see the consent that was recorded above.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('mini_apps.beta_consent');
      expect(
        await storage.hasConsented(
          userId: 'user-1',
          appId: 'app-1',
          version: '1.0.0',
        ),
        isTrue,
      );
    });
  });
}

/// Widget-level tests for the beta consent sheet UI rendered by
/// [showBetaConsentIfNeeded]. Together with `beta_consent_sheet_test.dart`
/// (which covers the storage logic) these confirm the full beta gate:
///
///   1. First launch: sheet renders title + body + BETA pill, plus the
///      release notes section when present.
///   2. Tapping "Continue" persists consent and resolves to true.
///   3. Tapping "Cancel" resolves to false and leaves consent unset.
///   4. Already-consented launches skip the sheet (no widget pump).
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/i18n/generated/app_localizations.dart';
import 'package:ilink/features/mini_apps/data/beta_consent_storage.dart';
import 'package:ilink/features/mini_apps/domain/mini_app.dart';
import 'package:ilink/features/mini_apps/domain/mini_app_track.dart';
import 'package:ilink/features/mini_apps/presentation/beta_consent_sheet.dart';
import 'package:ilink/kernel/access/domain/local_device_profile.dart';
import 'package:ilink/features/profile/state/local_profile_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ──────────────────────────────────────────────────────────────────────────────
// Fixtures
// ──────────────────────────────────────────────────────────────────────────────

const _testUser = LocalDeviceProfile(
  id: 'user-1',
  displayName: 'Test User',
  cars: [],
);

MiniApp _betaApp({
  String id = 'beta-app',
  String version = '1.1.0',
  String? releaseNotes = 'Fixed the thing.',
}) {
  return MiniApp(
    id: id,
    name: const {'en': 'Beta App'},
    description: const {'en': 'A beta app'},
    icon: 'https://cdn.example/icon.png',
    url: 'https://cdn.example/beta-app/',
    version: version,
    minHostVersion: '1.0.0',
    category: 'info',
    bundleUrl: 'https://cdn.example/beta-app/bundle.tar.gz',
    bundleSha256: 'a' * 64,
    isInstalled: false,
    track: MiniAppTrack.beta,
    releaseNotes: releaseNotes,
  );
}

/// AsyncNotifier override that returns [_testUser] synchronously.
class _StubLocalProfileController extends LocalProfileController {
  @override
  Future<LocalDeviceProfile> build() async => _testUser;
}

/// Pumps a [Material] host widget that exposes a button which, when
/// tapped, invokes [showBetaConsentIfNeeded] on [app] and stores the
/// awaited result in [resultCompleter].
Future<void> _pumpHost(
  WidgetTester tester, {
  required MiniApp app,
  required void Function(bool result) onResult,
  required ProviderContainer container,
}) async {
  // Prime the AsyncNotifier so `ref.read(localProfileProvider).value` is
  // populated synchronously when the consent gate runs. Without this
  // the gate sees `value == null` and treats the user as guest, which
  // breaks the seeded-consent fixture in the "already consented" case.
  await container.read(localProfileProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: const [
          S.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: S.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(
            builder: (ctx, ref, _) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  final ok = await showBetaConsentIfNeeded(ctx, ref, app);
                  onResult(ok);
                },
                child: const Text('TRIGGER'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// ──────────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────────

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('first launch shows title, body, BETA pill, and release notes', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        localProfileProvider.overrideWith(_StubLocalProfileController.new),
      ],
    );
    addTearDown(container.dispose);

    bool? result;
    await _pumpHost(
      tester,
      app: _betaApp(releaseNotes: 'Try the new UI'),
      onResult: (r) => result = r,
      container: container,
    );

    await tester.tap(find.text('TRIGGER'));
    await tester.pumpAndSettle();

    // Sheet contents.
    expect(find.text('Beta App'), findsOneWidget); // sheet title (l10n)
    // The sheet's chip uses a `_BetaBadge` subclass, so locate by text.
    expect(find.text('BETA'), findsOneWidget);
    expect(
      find.textContaining('beta version provided by the developer'),
      findsOneWidget,
    );
    // Release notes label + body.
    expect(find.text('Release notes'), findsOneWidget);
    expect(find.text('Try the new UI'), findsOneWidget);

    // Action buttons.
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    // Result not yet set — sheet still open.
    expect(result, isNull);
  });

  testWidgets('Continue persists consent and resolves true', (tester) async {
    final container = ProviderContainer(
      overrides: [
        localProfileProvider.overrideWith(_StubLocalProfileController.new),
      ],
    );
    addTearDown(container.dispose);

    bool? result;
    final app = _betaApp();
    await _pumpHost(
      tester,
      app: app,
      onResult: (r) => result = r,
      container: container,
    );

    await tester.tap(find.text('TRIGGER'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(result, isTrue);

    // Consent persisted for (userId, appId, version).
    final storage = container.read(betaConsentStorageProvider);
    expect(
      await storage.hasConsented(
        userId: _testUser.id,
        appId: app.id,
        version: app.version,
      ),
      isTrue,
    );
  });

  testWidgets('Cancel resolves false and does not persist consent', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        localProfileProvider.overrideWith(_StubLocalProfileController.new),
      ],
    );
    addTearDown(container.dispose);

    bool? result;
    final app = _betaApp();
    await _pumpHost(
      tester,
      app: app,
      onResult: (r) => result = r,
      container: container,
    );

    await tester.tap(find.text('TRIGGER'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isFalse);

    // No consent recorded.
    final storage = container.read(betaConsentStorageProvider);
    expect(
      await storage.hasConsented(
        userId: _testUser.id,
        appId: app.id,
        version: app.version,
      ),
      isFalse,
    );
  });

  testWidgets('already-consented launches skip the sheet and resolve true', (
    tester,
  ) async {
    // Pre-seed the consent so the sheet should not appear.
    SharedPreferences.setMockInitialValues({
      'mini_apps.beta_consent': '{"${_testUser.id}/beta-app/1.1.0": true}',
    });

    final container = ProviderContainer(
      overrides: [
        localProfileProvider.overrideWith(_StubLocalProfileController.new),
      ],
    );
    addTearDown(container.dispose);

    bool? result;
    await _pumpHost(
      tester,
      app: _betaApp(),
      onResult: (r) => result = r,
      container: container,
    );

    await tester.tap(find.text('TRIGGER'));
    await tester.pumpAndSettle();

    // Sheet must not have rendered.
    expect(find.text('BETA'), findsNothing);
    expect(find.text('Continue'), findsNothing);

    // But the gate resolved true so the launch can proceed.
    expect(result, isTrue);
  });
}

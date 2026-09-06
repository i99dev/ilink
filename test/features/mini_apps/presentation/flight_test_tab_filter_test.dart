/// Widget test for the [FlightTestTab] catalog filter.
///
/// The tab is the surface a flight tester opens to find ONLY the beta
/// builds they're invited to test. Backend already filters by
/// (tester_user_id == user_id AND status == accepted), so the
/// client-side filter just narrows the catalog response by
/// ``MiniApp.isBeta``. This test pins the narrowing behavior so a
/// future regression can't accidentally surface production apps in
/// the flight-test surface (or vice versa).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/i18n/generated/app_localizations.dart';
import 'package:ilink/features/mini_apps/domain/mini_app.dart';
import 'package:ilink/features/mini_apps/domain/mini_app_track.dart';
import 'package:ilink/features/mini_apps/presentation/widgets/flight_test_tab.dart';
import 'package:ilink/features/mini_apps/state/mini_app_providers.dart';

MiniApp _app({
  required String id,
  required MiniAppTrack track,
  String name = 'app',
}) {
  return MiniApp(
    id: id,
    name: {'en': name},
    description: const {'en': 'Test app.'},
    icon: 'https://cdn.example/$id/icon.png',
    url: 'https://cdn.example/$id/',
    version: '1.0.0',
    minHostVersion: '1.0.0',
    category: 'info',
    bundleUrl: 'https://cdn.example/$id/bundle.tar.gz',
    bundleSha256: 'a' * 64,
    track: track,
  );
}

class _StubCatalog extends MiniAppCatalogController {
  _StubCatalog(this._initial);
  final List<MiniApp> _initial;

  @override
  Future<List<MiniApp>> build() async => _initial;
}

Widget _wrap(Widget child) {
  return MaterialApp(
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    locale: const Locale('en'),
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('shows only beta apps; production apps are filtered out', (
    tester,
  ) async {
    final apps = <MiniApp>[
      _app(id: 'prod-app', track: MiniAppTrack.production, name: 'Prod App'),
      _app(id: 'beta-app-1', track: MiniAppTrack.beta, name: 'Beta One'),
      _app(id: 'beta-app-2', track: MiniAppTrack.beta, name: 'Beta Two'),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          miniAppCatalogProvider.overrideWith(() => _StubCatalog(apps)),
        ],
        child: _wrap(const FlightTestTab()),
      ),
    );
    // Let the AsyncNotifier resolve.
    await tester.pumpAndSettle();

    expect(find.text('Beta One'), findsOneWidget);
    expect(find.text('Beta Two'), findsOneWidget);
    expect(
      find.text('Prod App'),
      findsNothing,
      reason:
          'Production-track apps must not surface on the Flight Test '
          'tab — the whole point is a focused tester surface.',
    );
  });

  testWidgets('renders empty state with the CTA when no beta apps exist', (
    tester,
  ) async {
    final apps = <MiniApp>[
      _app(id: 'prod-only', track: MiniAppTrack.production, name: 'Prod Only'),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          miniAppCatalogProvider.overrideWith(() => _StubCatalog(apps)),
        ],
        child: _wrap(const FlightTestTab()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No active flight tests'), findsOneWidget);
    expect(find.text('Read the flight-test guide'), findsOneWidget);
    // Verify production apps don't slip into the empty surface either.
    expect(find.text('Prod Only'), findsNothing);
  });

  testWidgets('renders empty state when the catalog itself is empty', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          miniAppCatalogProvider.overrideWith(() => _StubCatalog(const [])),
        ],
        child: _wrap(const FlightTestTab()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No active flight tests'), findsOneWidget);
  });
}

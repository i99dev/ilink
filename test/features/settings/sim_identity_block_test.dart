/// Widget tests for the SIM-identity settings block.
///
/// `sim_identity_block.dart` is 821 LOC and had no widget coverage. The
/// security-relevant contract is the "what is the modem actually using
/// vs. what did the user spoof" surface: the OVERRIDDEN/REAL badge, the
/// shown ICCID, and the "Real prop:" disclosure that must appear ONLY
/// when an override is masking a real value. A silent regression here
/// would mislead a user about whether their real SIM identity is
/// exposed — exactly the kind of thing a test should pin.
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/kernel/i18n/generated/app_localizations.dart';
import 'package:ilink/kernel/sim/sim_identity_override.dart';
import 'package:ilink/kernel/sim/sim_identity_reader.dart';
import 'package:ilink/features/settings/presentation/widgets/sections/sim_identity_block.dart';

/// Seeded override notifier — no SharedPreferences round-trip.
class _SeedOverride extends SimIdentityOverrideController {
  _SeedOverride(this.seed);
  final SimIdentityOverride seed;
  @override
  Future<SimIdentityOverride> build() async => seed;
}

Widget _harness(ResolvedSimIdentity resolved) {
  return ProviderScope(
    overrides: [
      resolvedSimIdentityProvider.overrideWithValue(resolved),
      simIdentityOverrideProvider.overrideWith(
        // ignore: prefer_const_constructors — _SeedOverride is a
        // Notifier subclass; it cannot have a const constructor.
        () => _SeedOverride(SimIdentityOverride.empty),
      ),
    ],
    child: const MaterialApp(
      localizationsDelegates: [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: S.supportedLocales,
      locale: Locale('en'),
      home: Scaffold(body: SingleChildScrollView(child: SimIdentityBlock())),
    ),
  );
}

void main() {
  testWidgets('pass-through: shows real ICCID, REAL badge, no leak line', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _harness(
        const ResolvedSimIdentity(
          iccid: '8901000000000000001',
          imsi: '',
          overrideActive: false,
          realIccid: '8901000000000000001',
        ),
      ),
    );
    // SimIdentityBlock carries a perpetual animation (experimental
    // pulse) — never settles. Pump bounded frames: enough for the
    // seeded async override to resolve + first layout.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Current ICCID'), findsOneWidget);
    expect(find.text('8901000000000000001'), findsOneWidget);
    // Not spoofed → REAL badge, and the "Real prop:" disclosure must
    // NOT render (it only exists to expose a masked real value).
    expect(find.text('REAL'), findsOneWidget);
    expect(find.text('OVERRIDDEN'), findsNothing);
    expect(
      find.textContaining('Real prop:'),
      findsNothing,
      reason: 'no override active → nothing is being masked',
    );
  });

  testWidgets('override active: spoofed ICCID + OVERRIDDEN + real disclosed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _harness(
        const ResolvedSimIdentity(
          iccid: '8999999999999999999',
          imsi: '460011234567890',
          overrideActive: true,
          realIccid: '8901000000000000001',
        ),
      ),
    );
    // SimIdentityBlock carries a perpetual animation (experimental
    // pulse) — never settles. Pump bounded frames: enough for the
    // seeded async override to resolve + first layout.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Shown value is the spoof; badge flips; the real value is
    // explicitly disclosed so the user is never misled.
    expect(find.text('8999999999999999999'), findsOneWidget);
    expect(find.text('OVERRIDDEN'), findsOneWidget);
    expect(find.text('REAL'), findsNothing);
    expect(
      find.textContaining('Real prop: 8901000000000000001'),
      findsOneWidget,
    );
  });

  testWidgets('no SIM / shell unreachable: renders em-dash, no throw', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_harness(ResolvedSimIdentity.empty));
    // SimIdentityBlock carries a perpetual animation (experimental
    // pulse) — never settles. Pump bounded frames: enough for the
    // seeded async override to resolve + first layout.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Empty identity is a real state (no SIM, shell down) — the block
    // must degrade to a placeholder, not crash.
    expect(find.text('Current ICCID'), findsOneWidget);
    // Every empty field collapses to the same em-dash placeholder —
    // the point is it renders at least once and nothing threw.
    expect(find.text('—'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

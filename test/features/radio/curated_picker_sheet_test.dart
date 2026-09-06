import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/radio/domain/curated_playlist.dart';
import 'package:ilink/features/radio/domain/radio_facet.dart';
import 'package:ilink/features/radio/presentation/widgets/curated_picker_sheet.dart';
import 'package:ilink/features/radio/providers.dart';

/// Regression guard for the curated-picker row overflow: every list row
/// reserves the same 1px separator slot so it matches the fixed
/// `ListView.prototypeItem` extent. Before the fix, rows after the first
/// added a 1px Divider on top of the prototype height and Flutter reported
/// "BOTTOM OVERFLOWED BY 1.00 PIXELS" on every row.
void main() {
  CuratedIndexEntry lang(int i) => CuratedIndexEntry(
    id: 'lang$i',
    name: 'Language: Lang$i',
    count: i,
    urlPath: 'api/lang$i.json',
  );

  testWidgets('renders the facet list without a RenderFlex overflow', (
    tester,
  ) async {
    // Enough rows to exceed the viewport so the prototype extent is exercised
    // for the off-screen items too.
    final entries = [for (var i = 0; i < 40; i++) lang(i)];
    final index = CuratedIndex(generatedAt: DateTime(2026), entries: entries);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          curatedIndexProvider.overrideWith((ref) => Future.value(index)),
          curatedFacetGroupsProvider.overrideWithValue([
            FacetGroup(facet: RadioFacet.language, entries: entries),
          ]),
        ],
        child: const MaterialApp(home: Scaffold(body: CuratedPickerSheet())),
      ),
    );
    await tester.pumpAndSettle();

    // The list rendered (labels have the "Language: " facet prefix stripped)…
    expect(find.text('Lang0'), findsOneWidget);
    // …and laying it out produced no overflow exception.
    expect(tester.takeException(), isNull);
  });
}

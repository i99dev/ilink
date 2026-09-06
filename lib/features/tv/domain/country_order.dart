import 'tv_catalog.dart';

/// How the TV country chips are ordered. The user picks one; [custom] is
/// entered implicitly the moment they drag or hide a country.
enum TvCountrySort {
  /// Middle East / MENA countries first (see [kMiddleEastCountryCodes]), then
  /// everything else in catalogue order. This is the **fleet default** — most
  /// users are in the region, so their countries lead without any setup.
  middleEast,

  /// Catalogue/server order — the `index.json` order, untouched.
  catalogDefault,

  /// Alphabetical by display name (locale-naive `compareTo`; good enough for
  /// a chip row, and stable).
  alpha,

  /// Most channels first (`count` desc), ties broken by name for stability.
  channelCount,

  /// The user's hand-ordered list (see [CountryOrderPref.customOrder]).
  custom;

  static TvCountrySort fromName(String? name) => values.firstWhere(
    (s) => s.name == name,
    orElse: () => TvCountrySort.middleEast,
  );
}

/// Curated priority order for [TvCountrySort.middleEast] — the regional
/// default. Codes are catalogue country codes (lowercase ISO-3166-alpha-2).
/// Only codes actually present in the catalogue surface; the rest of the
/// catalogue follows in its own order. Edit this one list to retune the
/// regional default — nothing else needs to change. Gulf first (the bulk of
/// the fleet), then Levant, then Arab North Africa, then non-Arab neighbours.
const kMiddleEastCountryCodes = <String>[
  // GCC
  'ae', 'sa', 'qa', 'kw', 'bh', 'om',
  // Levant + Iraq + Yemen
  'jo', 'lb', 'sy', 'ps', 'iq', 'ye',
  // Nile + Maghreb (Arab North Africa)
  'eg', 'sd', 'ly', 'tn', 'dz', 'ma', 'mr',
  // Non-Arab neighbours
  'ir', 'tr',
];

/// The user's persisted country-ordering preference.
///
/// Persisted by **country code** (e.g. `ae`), never by snapshot: country codes
/// are stable across the daily catalogue rebuild (counts/paths churn, codes do
/// not), so the user's order + hidden set survive a rebuild for free. This is
/// deliberately leaner than `TvFavoritesStore`, which must snapshot whole
/// channels because catalogue *channels* have no stable server-side id.
class CountryOrderPref {
  const CountryOrderPref({
    this.mode = TvCountrySort.middleEast,
    this.customOrder = const [],
    this.hidden = const {},
  });

  /// The fresh-install default — Middle East first, nothing hidden.
  static const empty = CountryOrderPref();

  final TvCountrySort mode;

  /// Ordered country codes for [TvCountrySort.custom]. Codes not present here
  /// (newly added to the catalogue since the user last ordered) are appended
  /// in catalogue order by [applyCountryOrder]; codes no longer in the
  /// catalogue are ignored. Irrelevant for the non-custom modes.
  final List<String> customOrder;

  /// Country codes the user has hidden from the chip row. Honoured in every
  /// mode. [applyCountryOrder] refuses to hide the *last* visible country so
  /// the page can never become empty.
  final Set<String> hidden;

  CountryOrderPref copyWith({
    TvCountrySort? mode,
    List<String>? customOrder,
    Set<String>? hidden,
  }) => CountryOrderPref(
    mode: mode ?? this.mode,
    customOrder: customOrder ?? this.customOrder,
    hidden: hidden ?? this.hidden,
  );

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'order': customOrder,
    'hidden': hidden.toList(growable: false),
  };

  factory CountryOrderPref.fromJson(Map<String, dynamic> j) => CountryOrderPref(
    mode: TvCountrySort.fromName(j['mode'] as String?),
    customOrder: ((j['order'] as List?) ?? const []).whereType<String>().toList(
      growable: false,
    ),
    hidden: ((j['hidden'] as List?) ?? const []).whereType<String>().toSet(),
  );

  @override
  bool operator ==(Object other) =>
      other is CountryOrderPref &&
      other.mode == mode &&
      _listEq(other.customOrder, customOrder) &&
      _setEq(other.hidden, hidden);

  @override
  int get hashCode => Object.hash(
    mode,
    Object.hashAll(customOrder),
    Object.hashAllUnordered(hidden),
  );
}

/// Pure transform: resolve [countries] (catalogue order) into the list the
/// chip row should render, applying the user's [pref]. Side-effect-free and
/// UI-free so it is unit-testable in isolation and memoisable behind a
/// `Provider`.
///
/// Invariants:
///   * Result preserves catalogue identity (returns the same
///     [TvCatalogGroup] objects, just reordered/filtered).
///   * [CountryOrderPref.hidden] is filtered out — UNLESS that would empty the
///     row, in which case nothing is hidden (fail-safe: a hidden-everything
///     pref must never strand the user on a blank page).
///   * In [TvCountrySort.custom] / [TvCountrySort.middleEast], the lead codes
///     (user order / [kMiddleEastCountryCodes]) come first in that order; any
///     remaining catalogue country is appended in catalogue order (so a
///     freshly-added country shows up rather than vanishing).
List<TvCatalogGroup> applyCountryOrder(
  List<TvCatalogGroup> countries,
  CountryOrderPref pref,
) {
  if (countries.isEmpty) return countries;

  // 1. Hide — but never strand the user on an empty row.
  var visible = pref.hidden.isEmpty
      ? countries
      : countries.where((c) => !pref.hidden.contains(c.key)).toList();
  if (visible.isEmpty) visible = List.of(countries);

  // 2. Order.
  switch (pref.mode) {
    case TvCountrySort.catalogDefault:
      return List.unmodifiable(visible);
    case TvCountrySort.alpha:
      final sorted = List.of(visible)
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return List.unmodifiable(sorted);
    case TvCountrySort.channelCount:
      final sorted = List.of(visible)
        ..sort((a, b) {
          final byCount = b.count.compareTo(a.count);
          return byCount != 0 ? byCount : a.name.compareTo(b.name);
        });
      return List.unmodifiable(sorted);
    case TvCountrySort.middleEast:
      return _leadThenCatalog(visible, kMiddleEastCountryCodes);
    case TvCountrySort.custom:
      return _leadThenCatalog(visible, pref.customOrder);
  }
}

/// Place [leadCodes] first (in that order, skipping codes not in [visible]),
/// then every remaining country in its catalogue order. Shared by the
/// `custom` (user order) and `middleEast` (curated regional order) modes —
/// both are "a priority list, then the rest." Catalogue-new countries surface
/// in the tail instead of disappearing.
List<TvCatalogGroup> _leadThenCatalog(
  List<TvCatalogGroup> visible,
  List<String> leadCodes,
) {
  final byCode = {for (final c in visible) c.key: c};
  final ordered = <TvCatalogGroup>[];
  final placed = <String>{};
  for (final code in leadCodes) {
    final g = byCode[code];
    if (g != null && placed.add(code)) ordered.add(g);
  }
  for (final g in visible) {
    if (placed.add(g.key)) ordered.add(g);
  }
  return List.unmodifiable(ordered);
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _setEq(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

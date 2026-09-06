/// The single source of truth for how the curated radio catalogue is sliced.
///
/// The catalogue (ilink/m3u-radio-music-playlists, built by m3u-rest-api)
/// ships every playlist with its name prefixed `"<Facet>: <Value>"` — e.g.
/// `"Country: France"`, `"Category: Jazz"`, `"Language: Arabic"`. This enum
/// owns that wire-format contract: parsing the prefix, the display order of
/// the facet chips, and the human label. No other file should string-match
/// the prefix — call [split] instead, so the contract lives in one place.
enum RadioFacet {
  category('Category', 'Categories'),
  country('Country', 'Countries'),
  language('Language', 'Languages'),

  /// Anything without a recognised prefix (legacy flat playlists, user
  /// imports surfaced through the same model). Keeps the picker total-safe.
  other('', 'Other');

  const RadioFacet(this.prefix, this.plural);

  /// The exact prefix the catalogue emits before [_separator] in the name.
  final String prefix;

  /// Plural label for the facet chip + search hint.
  final String plural;

  /// Fixed display order for the facet chips.
  static const List<RadioFacet> order = [category, country, language, other];

  static const String _separator = ': ';

  /// Parse a catalogue name into `(facet, value)`. An unknown or absent
  /// prefix yields `(RadioFacet.other, <original name>)` so callers never
  /// have to special-case malformed input.
  static (RadioFacet, String) split(String name) {
    final i = name.indexOf(_separator);
    if (i > 0) {
      final prefix = name.substring(0, i);
      for (final f in order) {
        if (f != other && f.prefix == prefix) {
          return (f, name.substring(i + _separator.length));
        }
      }
    }
    return (other, name);
  }
}

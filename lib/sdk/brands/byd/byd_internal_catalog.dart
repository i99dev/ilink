/// BYD catalog adapter — implements [CarCatalog] from the bundled
/// `assets/byd/catalog.tsv` + (optional) `catalog_meta.yaml`.
///
/// Loaded once at app boot via [bydCatalogProvider]. Subsequent
/// lookups are sync map operations — no I/O after init.
library;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../car/catalog.dart';
import '../../car/feature.dart';

class BydCatalog implements CarCatalog {
  BydCatalog._(this._byName, this._byNamespace, this._byCategory);

  final Map<String, CarFeature> _byName;
  final Map<String, List<CarFeature>> _byNamespace;
  final Map<String, List<CarFeature>> _byCategory;

  /// Load + parse the BYD catalog from bundled assets. The TSV
  /// holds 13k+ entries — parse takes ~50 ms on a typical IVI head
  /// unit. Done once at boot; the resulting [BydCatalog] is held
  /// for the app's lifetime via [bydCatalogProvider].
  static Future<BydCatalog> load() async {
    final tsv = await rootBundle.loadString('assets/byd/catalog.tsv');
    // Meta is optional — older builds may not have shipped it. The
    // parse below tolerates an absent file.
    String? meta;
    try {
      meta = await rootBundle.loadString('assets/byd/catalog_meta.yaml');
    } catch (_) {
      meta = null;
    }
    return fromContent(tsv, meta);
  }

  /// Parse a catalog from raw TSV + optional meta-YAML content. Split out
  /// of [load] so the parse — including the name-form normalisation below
  /// — is unit-testable without a `rootBundle`/asset binding.
  static BydCatalog fromContent(String tsv, String? meta) {
    final overrides = _parseMeta(meta);
    // catalog.tsv mixes namespaced (`Ac.AC_TEMP`) and raw (`AC_TEMP`) row
    // names, while the meta overlay is keyed by the namespaced form. Index
    // each override by BOTH its full key and its namespace-stripped form,
    // so a raw-form catalog.tsv row still picks up its override — before
    // this it silently missed (raw rows got only a humanised description
    // + an empty category).
    final overridesByEither = <String, Map<String, dynamic>>{};
    for (final e in overrides.entries) {
      overridesByEither[e.key] = e.value;
      final dot = e.key.indexOf('.');
      if (dot >= 0) {
        overridesByEither.putIfAbsent(e.key.substring(dot + 1), () => e.value);
      }
    }

    final byName = <String, CarFeature>{};
    final byNs = <String, List<CarFeature>>{};
    final byCat = <String, List<CarFeature>>{};

    for (final line in tsv.split('\n')) {
      if (line.isEmpty) continue;
      final tab = line.indexOf('\t');
      if (tab < 0) continue;
      final name = line.substring(0, tab);
      final idStr = line.substring(tab + 1).trim();
      final id = int.tryParse(idStr);
      if (id == null) continue;

      final dot = name.indexOf('.');
      final namespace = dot < 0 ? '' : name.substring(0, dot);
      final shortName = dot < 0 ? name : name.substring(dot + 1);

      final ov = overridesByEither[name];
      final desc = ov?['desc'] as String? ?? _humanise(shortName);
      final unit = ov?['unit'] as String?;
      final semantics = ov?['semantics'] as String?;
      final dtHint = (ov?['dt_hint'] as num?)?.toInt();
      final readOnly = (ov?['read_only'] as bool?) ?? true;
      final categoryRaw = ov?['category'] as String? ?? namespace.toLowerCase();
      final valueKind = _parseValueKind(ov?['value_kind'] as String?);

      final feature = CarFeature(
        name: name,
        id: id,
        namespace: namespace,
        description: desc,
        unit: unit,
        semantics: semantics,
        dtHint: dtHint,
        readOnly: readOnly,
        valueKind: valueKind,
        category: categoryRaw.isEmpty ? null : categoryRaw,
      );

      byName[name] = feature;
      if (namespace.isNotEmpty) {
        (byNs[namespace] ??= []).add(feature);
      }
      if (categoryRaw.isNotEmpty) {
        (byCat[categoryRaw] ??= []).add(feature);
      }
    }

    return BydCatalog._(byName, byNs, byCat);
  }

  // ── Implementation ───────────────────────────────────────────────

  @override
  int get size => _byName.length;

  @override
  CarFeature? feature(String name) => _byName[name];

  @override
  Iterable<CarFeature> all() => _byName.values;

  @override
  Iterable<CarFeature> byCategory(String category) =>
      _byCategory[category] ?? const [];

  @override
  Iterable<CarFeature> byNamespace(String namespace) =>
      _byNamespace[namespace] ?? const [];

  @override
  List<String> namespaces() => _byNamespace.keys.toList()..sort();

  @override
  List<String> categories() => _byCategory.keys.toList()..sort();

  @override
  Iterable<CarFeature> searchByDescription(String query) {
    final q = query.toLowerCase();
    return _byName.values.where((f) => f.description.toLowerCase().contains(q));
  }

  // ── Helpers ──────────────────────────────────────────────────────

  /// Parse the (optional) catalog_meta.yaml. Hand-rolled parser —
  /// avoids the `yaml` package dependency for the trivial subset we
  /// need (top-level keyed entries with scalar fields). Robust to
  /// the standard YAML shape produced by the meta file:
  ///
  ///   "Door.DOOR_LOCK_…":
  ///     desc: "Vehicle lock state"
  ///     semantics: "1=locked, 2=unlocked"
  ///
  /// Returns name → field map for every entry that had any override.
  static Map<String, Map<String, dynamic>> _parseMeta(String? content) {
    final out = <String, Map<String, dynamic>>{};
    if (content == null) return out;
    String? currentKey;
    Map<String, dynamic>? current;
    for (final raw in content.split('\n')) {
      final line = raw.trimRight();
      if (line.isEmpty || line.trimLeft().startsWith('#')) continue;
      // Top-level key: starts at column 0, ends with ':'
      if (!line.startsWith(' ') && line.endsWith(':')) {
        // Strip surrounding quotes if present
        var k = line.substring(0, line.length - 1);
        if (k.startsWith('"') && k.endsWith('"')) {
          k = k.substring(1, k.length - 1);
        }
        currentKey = k;
        current = <String, dynamic>{};
        out[currentKey] = current;
        continue;
      }
      // Nested field: 2-space indent, "key: value"
      if (current != null && line.startsWith('  ') && !line.startsWith('   ')) {
        final stripped = line.substring(2);
        final colon = stripped.indexOf(':');
        if (colon < 0) continue;
        final key = stripped.substring(0, colon).trim();
        var value = stripped.substring(colon + 1).trim();
        if (value.startsWith('"') && value.endsWith('"')) {
          value = value.substring(1, value.length - 1);
        }
        // Coerce common scalar types
        if (value == 'true' || value == 'false') {
          current[key] = value == 'true';
        } else if (int.tryParse(value) != null) {
          current[key] = int.parse(value);
        } else {
          current[key] = value;
        }
      }
    }
    return out;
  }

  static CarValueKind _parseValueKind(String? raw) {
    switch (raw) {
      case 'double':
        return CarValueKind.doubleT;
      case 'bytes':
        return CarValueKind.bytesT;
      case 'int_array':
        return CarValueKind.intArrayT;
      default:
        return CarValueKind.intT;
    }
  }

  /// Convert `BODYWORK_LEFT_HAND_FRONT_DOOR` → `"Bodywork left hand
  /// front door"`. Used as the description fallback when no
  /// catalog_meta.yaml override exists.
  static String _humanise(String shortName) {
    return shortName
        .toLowerCase()
        .replaceAll('_', ' ')
        .replaceFirstMapped(
          RegExp(r'^[a-z]'),
          (m) => m.group(0)!.toUpperCase(),
        );
  }
}

/// App-wide singleton. Loaded once at first read; subsequent reads
/// hit the cache.
final bydCatalogProvider = FutureProvider<BydCatalog>((ref) async {
  return BydCatalog.load();
});

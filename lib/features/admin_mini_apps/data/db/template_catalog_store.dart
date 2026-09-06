/// SQLite-backed cache of the command-template catalog.
///
/// The dispatcher needs the template (tier, requires_step_up, slot
/// schema, shell text) on every privileged op. Without a cache, each
/// op would force a backend fetch — defeating Phase 8's whole point.
/// The cache is keyed by ``cert_hash`` so a fresh cert (e.g. catalog
/// version bump on the dev's side) deterministically invalidates the
/// stale rows.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../domain/admin_op.dart' show CommandTemplate, ParamRule;

class TemplateCatalogStore {
  TemplateCatalogStore(this._db);

  final Database _db;

  /// Replace the entire cached catalog for a given cert hash. Used
  /// after a successful fetch from the server (or, for now, after
  /// decoding the dev cert — the cert payload IS the catalog
  /// snapshot for the dev's grants).
  ///
  /// Atomic: clears stale rows + inserts fresh ones in one txn so a
  /// concurrent reader never sees a half-populated catalog.
  Future<void> replaceForCert({
    required String certHash,
    required List<CommandTemplate> templates,
    DateTime? fetchedAt,
  }) async {
    final ts = (fetchedAt ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      await txn.delete(
        'template_catalog',
        where: 'cert_hash = ?',
        whereArgs: [certHash],
      );
      for (final t in templates) {
        await txn.insert('template_catalog', {
          'cert_hash': certHash,
          'template_id': t.id,
          'permission_id': t.permissionId,
          'tier': t.tier.index + 1, // tier1 → 1, tier2 → 2
          'requires_step_up': t.requiresStepUp ? 1 : 0,
          'category': t.category,
          'shell_template': t.shellTemplate,
          'param_schema_json': jsonEncode(_paramSchemaToJson(t.paramSchema)),
          'description': t.description,
          'fetched_at': ts,
        });
      }
    });
  }

  /// Lookup the template the dispatcher needs for one op. Returns
  /// null if the cache doesn't have it (caller falls back to a
  /// fresh fetch — typically because the cert was just rotated).
  Future<CommandTemplate?> lookup({
    required String certHash,
    required String templateId,
  }) async {
    final rows = await _db.query(
      'template_catalog',
      where: 'cert_hash = ? AND template_id = ?',
      whereArgs: [certHash, templateId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// All templates in the cache for a cert. Used by the Settings
  /// "what can this app do?" UI.
  Future<List<CommandTemplate>> listForCert(String certHash) async {
    final rows = await _db.query(
      'template_catalog',
      where: 'cert_hash = ?',
      whereArgs: [certHash],
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// Clear the cache for a cert — called when revocation lands or
  /// when the dev publishes a new cert.
  Future<int> clearForCert(String certHash) async {
    return _db.delete(
      'template_catalog',
      where: 'cert_hash = ?',
      whereArgs: [certHash],
    );
  }

  static CommandTemplate _fromRow(Map<String, Object?> row) {
    return CommandTemplate.fromJson({
      'id': row['template_id'],
      'permissionId': row['permission_id'],
      'tier': row['tier'],
      'requiresStepUp': (row['requires_step_up'] as int) == 1,
      'category': row['category'],
      'shellTemplate': row['shell_template'],
      'paramSchema': jsonDecode(row['param_schema_json'] as String) as Map,
      'description': row['description'],
    });
  }

  static Map<String, Object?> _paramSchemaToJson(Object schema) {
    // CommandTemplate stores its paramSchema as ``Map<String, ParamRule>``.
    // Each subclass owns its own ``toMiniAppJson`` — round-trippable
    // with ``ParamRule.fromJson`` and byte-equal with the SDK's wire
    // shape. Single source of truth for the rule serialisation lives
    // on the rule classes themselves (see ``admin_op.dart``); this
    // function is just the dispatch glue.
    if (schema is! Map) return const {};
    final out = <String, Object?>{};
    for (final entry in schema.entries) {
      final rule = entry.value;
      if (rule is ParamRule) {
        out[entry.key as String] = rule.toMiniAppJson();
      }
    }
    return out;
  }
}

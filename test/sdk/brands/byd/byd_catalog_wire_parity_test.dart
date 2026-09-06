import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/sdk/brands/byd/byd_catalog.dart';
import 'package:ilink/sdk/car/public_catalog.dart';

/// Catalog ↔ wire parity test.
///
/// Phase 3 of the centralisation plan added a `wireActionId` field to
/// every `PublicCatalogEntry` whose write surface routes through a
/// FAST-actions textproto entry. This test enforces the invariant that
/// every populated `wireActionId` actually exists as an `action_id`
/// (or `macro_id`) in `.secrets/car_table/*.textproto` — the same
/// source `UnitDispatcher` consults at runtime.
///
/// Together with [registry_wire_parity_test], this triple-locks the
/// three-namespace bridge:
///
///   * registry ↔ wire   — `test/core/car/commands/registry_wire_parity_test.dart`
///   * catalog ↔ wire    — this file (Phase 3)
///   * catalog ↔ registry — implicit by transitivity once both pass
///
/// Phase 2 (textproto rename) deletes both this test and the registry
/// one — `writeActionId` becomes equal to the wire id, parity is by
/// construction. Phase 4 deletes the resolves in the registry domain
/// files; the registry id IS the wire id and the catalog is the
/// single source of truth.
void main() {
  group('Public catalog ↔ wire id parity', () {
    final secretsRoot = Directory('.secrets/car_table');
    late Set<String> wireIds;
    final PublicCatalog catalog = BydPublicCatalog.build();

    setUpAll(() {
      if (!secretsRoot.existsSync()) {
        // Skip silently — submodule not initialised on this checkout.
        // The release-build CI runs with secrets and re-verifies.
        return;
      }
      final actionIdRe = RegExp(r'action_id:\s*"([^"]+)"');
      final macroIdRe = RegExp(r'macro_id:\s*"([^"]+)"');
      wireIds = {};
      for (final dir in [secretsRoot, Directory('.secrets/car_table/parts')]) {
        if (!dir.existsSync()) continue;
        for (final entity in dir.listSync()) {
          if (entity is! File || !entity.path.endsWith('.textproto')) {
            continue;
          }
          final text = entity.readAsStringSync();
          for (final m in actionIdRe.allMatches(text)) {
            wireIds.add(m.group(1)!);
          }
          for (final m in macroIdRe.allMatches(text)) {
            wireIds.add(m.group(1)!);
          }
        }
      }
    });

    test(
      'every catalog entry with wireActionId resolves to a textproto wire id',
      () {
        if (!secretsRoot.existsSync()) {
          // ignore: avoid_print
          print(
            'byd_catalog_wire_parity: skipping — .secrets/car_table not '
            'initialised on this checkout.',
          );
          return;
        }
        expect(
          wireIds,
          isNotEmpty,
          reason:
              '.secrets/car_table/*.textproto produced no action_ids; '
              'parser regex broken or submodule empty.',
        );

        final missing = <String, String>{}; // signal name → wireActionId
        for (final entry in catalog.all()) {
          final wid = entry.wireActionId;
          if (wid == null) continue;
          if (!wireIds.contains(wid)) {
            missing[entry.name] = wid;
          }
        }

        if (missing.isNotEmpty) {
          final lines = missing.entries
              .map((e) => '  ${e.key}.wireActionId = "${e.value}"')
              .join('\n');
          fail(
            'These catalog entries declare a wireActionId that is NOT '
            'in the textproto. Either add a matching '
            '`fast_actions { action_id: ... }` row or null out the '
            'wireActionId on the catalog entry:\n$lines',
          );
        }
      },
    );

    test('writeable FAST-path signals without wireActionId are flagged', () {
      if (!secretsRoot.existsSync()) return;
      // Every signal that's `writeable: true` AND routes through the
      // FAST wire (i.e. NOT `binderOnly: true`) should carry a
      // `wireActionId`. Entries that fail this are the actionable
      // Phase 3 backfill list. Binder-only signals are exempt because
      // they have no textproto row to point at.
      final missing =
          catalog
              .all()
              .where(
                (e) => e.writeable && !e.binderOnly && e.wireActionId == null,
              )
              .map((e) => e.name)
              .toList()
            ..sort();
      if (missing.isNotEmpty) {
        // ignore: avoid_print
        print(
          'byd_catalog_wire_parity: writeable FAST-path signals without '
          'wireActionId (awaiting Phase 3 backfill or transport '
          'classification) — $missing',
        );
      }
      // Print binder-only count separately so the totals are visible
      // when classification changes — keeps the audit log honest.
      final binder = catalog
          .all()
          .where((e) => e.writeable && e.binderOnly)
          .length;
      // ignore: avoid_print
      print(
        'byd_catalog_wire_parity: $binder writeable signals classified as '
        'binderOnly (non-FAST transport, exempt from wire parity).',
      );
    });

    test(
      'every textproto FAST action_id has a catalog entry pointing at it',
      () {
        // Reverse parity: the catalog should be a SUPERSET of the wire
        // action surface. If the daemon recognises an action_id but no
        // catalog entry references it, mini-apps and the registry have
        // no documented way to dispatch it — which is exactly the
        // three-namespace drift Phase 1-4 set out to close. Any action
        // exercised by the registry directly (via bare-const wire id)
        // but NOT mirrored in the catalog is acceptable AS LONG AS it
        // appears in the exempt list below; everything else fails.
        if (!secretsRoot.existsSync()) return;

        // Wire ids that exist as direct registry dispatches with no
        // catalog read-state counterpart. Categorised so the exempt
        // list itself documents the design choice — adding to this
        // list should require updating one of the categories.
        const exempt = <String>{
          // Bulk-write triggers (no per-state read; the per-door read
          // state lives in `lock_lf` etc.). Registry dispatches these
          // directly via bare-const CarCommand.
          'door.unlock',
          'door.trunk.open',
          'door.trunk.close',
          'hood.open',
          'hood.close',
          'hood.stop',

          // Window/sunroof verbs — wire is per-pane, registry fans out
          // verbs (open/close/stop/down) via the `_winCmd` helper.
          // Catalog covers the read state (window_lf, sunroof_pct).
          'window.fl',
          'window.rf',
          'window.rl',
          'window.rr',
          'sunroof.ctl',
          'sunroof.percent',

          // Light triggers with no state surface in the catalog.
          'light.head.off',
          'light.flash',
          'light.find_car',

          // Comfort/massage parameterised dispatches — catalog covers
          // the per-seat read state; the registry's `comfort.massage`
          // resolves to massage.<seat>.<field> at dispatch time.
          'comfort.frag.off',
          'comfort.atmos.off',
          'comfort.atmos.bright',
          'comfort.atmos.color',

          // Fragrance (unit_actions). The catalog has perfume_* read
          // state (current type, bottle names + surplus) but no
          // BYD-named ON-state signal — `Ac.AC_FRAGRANCE_*_FEEDBACK`
          // doesn't include an on/off mirror. Registry dispatches
          // these directly via bare-const wire id. Add a catalog
          // mirror when the on-state framework name is confirmed
          // on-car.
          'comfort.frag.on',
          'frag.select',
          'frag.status',
        };

        final referenced = <String>{};
        for (final entry in catalog.all()) {
          final wid = entry.wireActionId;
          if (wid != null) referenced.add(wid);
        }

        final orphans =
            wireIds
                .where((id) => !referenced.contains(id) && !exempt.contains(id))
                .toList()
              ..sort();
        if (orphans.isNotEmpty) {
          fail(
            'These textproto action_ids have NO catalog entry pointing at '
            'them via wireActionId AND are not in the documented exempt '
            'list. Either add a catalog _Sig row with the matching '
            'wireActionId or, if the action is intentionally registry-only, '
            'add it to the `exempt` set in this test with a category '
            'comment:\n${orphans.map((s) => '  $s').join('\n')}',
          );
        }
        // ignore: avoid_print
        print(
          'byd_catalog_wire_parity: ${referenced.length}/${wireIds.length} '
          'textproto action_ids mirrored in the catalog; '
          '${exempt.length} documented as registry-only.',
        );
      },
    );

    test('wireActionId is consistent with writeActionId direction', () {
      // Pre-Phase-2 invariant: if a signal has BOTH writeActionId and
      // wireActionId, the writeActionId is the brand-neutral aspirational
      // string and wireActionId is the daemon-known id. They are
      // expected to be DIFFERENT (the whole reason wireActionId exists
      // is to bridge the namespace gap). Post-Phase-2 they will match.
      //
      // This test prints the bridge pairs so reviewers can spot any
      // accidental same-value backfill — it does not fail.
      if (!secretsRoot.existsSync()) return;
      final bridges = <String, String>{};
      for (final entry in catalog.all()) {
        final wid = entry.wireActionId;
        final aid = entry.writeActionId;
        if (wid != null && aid != null) {
          bridges[aid] = wid;
        }
      }
      // ignore: avoid_print
      print(
        'byd_catalog_wire_parity: ${bridges.length} writeActionId → wireActionId '
        'bridges populated (Phase 2 will collapse these to identity).',
      );
    });
  });
}

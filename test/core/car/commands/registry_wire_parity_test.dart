import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/_car_domain/command/registry.dart';

/// Registry-vs-wire parity test.
///
/// Every `CarCommand` whose dispatch crosses the bridge must end up at
/// a wire id the Kotlin `UnitDispatcher` knows about. There are two
/// paths to wire-truth today:
///
///   1. `cmd.id` is itself a wire id — the router dispatches it verbatim
///      (no `resolve:` callback set).
///   2. `cmd.resolve` returns a `ResolvedAction(actionId, …)` — the
///      router dispatches the resolved id. We can probe a representative
///      args map and assert the resolved id is wire-known.
///
/// Wire-knownness is read from `android/app/src/main/assets/offline/car_table.textproto` —
/// `action_id:` rows. This is the same source `UnitDispatcher` loads at
/// runtime via `EncryptedCarTableSource`, so a passing test = the
/// command WILL dispatch at runtime.
///
/// This test catches the entire class of bug the 2026-05-13 audit
/// surfaced (climate.*, window.*, sunroof.*, seat.heat.*, seat.vent.*,
/// door.trunk.*) — see docs/car-sdk-layers/command-methodology.md.
///
/// **Methodology** — fixes go in the textproto + registry (one
/// namespace) or via a `resolve:` callback (transitional). They do NOT
/// go in this test as exemptions; an entry in `_knownDartOnly` here is
/// a debt marker, not a fix.
void main() {
  group('CarCommand registry ↔ wire id parity', () {
    final tableRoot = Directory('android/app/src/main/assets/offline');
    late Set<String> wireIds;

    setUpAll(() {
      expect(
        tableRoot.existsSync(),
        isTrue,
        reason: 'Public local tables must be checked in.',
      );
      final actionIdRe = RegExp(r'action_id:\s*"([^"]+)"');
      final macroIdRe = RegExp(r'macro_id:\s*"([^"]+)"');
      wireIds = {};
      for (final dir in [
        tableRoot,
        Directory('android/app/src/main/assets/offline/car_table_parts'),
      ]) {
        if (!dir.existsSync()) continue;
        for (final entity in dir.listSync()) {
          if (entity is! File || !entity.path.endsWith('car_table.textproto')) {
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

    test('every routable CarCommand reaches a wire id', () {
      // Phase 1 wire-bridge landed (2026-05-14): the drifted
      // `climate.*`, `door.trunk.*`, `comfort.frag.*`, `comfort.atmos`,
      // and per-verb `window.<pos>.<verb>` registry ids now ship
      // `resolve:` callbacks that map back to the textproto's wire
      // action_ids. This test re-enables to lock that work in:
      // every command either (a) has a wire id matching cmd.id,
      // (b) resolves to one, or (c) is allowlisted in [_knownDartOnly]
      // for a documented reason (binder-only, aggregate, etc.).
      //
      // Phase 2 deletes the resolves once the textproto is renamed.
      expect(
        wireIds,
        isNotEmpty,
        reason:
            'android/app/src/main/assets/offline/car_table.textproto produced no action_ids; '
            'parser regex broken or submodule empty.',
      );

      final missing = <String, String>{}; // registry id → reason
      for (final cmd in commandRegistry.values) {
        if (_knownDartOnly.contains(cmd.id)) continue;

        if (cmd.resolve != null) {
          // Probe the resolver with a representative args map. For
          // group-templated commands (massage seat/field, atmos field)
          // we iterate the documented value sets and require ALL of
          // them to resolve to wire-known ids.
          final probes = _resolveProbeArgs(cmd.id);
          for (final args in probes) {
            final resolved = cmd.resolve!(args);
            if (!wireIds.contains(resolved.actionId)) {
              missing[cmd.id] =
                  'resolve($args) → ${resolved.actionId} '
                  '(not a wire id)';
              break;
            }
          }
        } else {
          // No transform — cmd.id IS the wire id.
          if (!wireIds.contains(cmd.id)) {
            missing[cmd.id] = 'no wire action_id with id="${cmd.id}"';
          }
        }
      }

      if (missing.isNotEmpty) {
        final lines = missing.entries
            .map((e) => '  ${e.key}: ${e.value}')
            .join('\n');
        fail(
          'These registered CarCommands cannot be dispatched at runtime — '
          'either add a `fast_actions { action_id: ... }` block to the '
          'textproto, add a `resolve:` callback that maps to an existing '
          'wire id, or rename the registry id to match a wire id:\n$lines',
        );
      }
    });

    test('wire ids without any registry entry are flagged for visibility', () {
      // Build the set of wire ids the registry reaches (directly or via
      // resolve). Anything in wireIds but NOT in this set is dispatchable
      // only from callers that send wire ids directly (compat dev bench,
      // voice tools using ActionIds.*) — not strictly an error, but worth
      // surfacing so we notice if a wire entry has no UI / voice surface.
      final reached = <String>{};
      for (final cmd in commandRegistry.values) {
        if (_knownDartOnly.contains(cmd.id)) continue;
        if (cmd.resolve != null) {
          for (final args in _resolveProbeArgs(cmd.id)) {
            reached.add(cmd.resolve!(args).actionId);
          }
        } else {
          reached.add(cmd.id);
        }
      }
      final orphan = wireIds.difference(reached);
      if (orphan.isNotEmpty) {
        // ignore: avoid_print
        print(
          'registry_wire_parity: wire ids with no CarCommand reach — '
          '$orphan. These are only callable from voice tools using '
          'ActionIds.* or dev-bench callers.',
        );
      }
    });
  });
}

/// Registry IDs that are intentionally Dart-only or not yet wired.
/// Adding to this list is a load-bearing decision — the entry skips the
/// parity check entirely.
///
/// Buckets (keep them grouped so future cleanup can pick off one bucket
/// at a time):
///
///   1. **In-app player.** Never crosses the bridge — the radio runs
///      inside the Dart process, no daemon-side actuator.
///   2. **Status special-case.** `car.status` reaches a custom router
///      branch, not a registered action_id.
///   3. **Binder-only.** No FAST wire path on Leopard 8; would route
///      through `acTransact` (IAcAirConditioner properties / IAcSeat)
///      when that path gets wired into [CarCommandRouter]. Until then
///      dispatch fails with `tool_not_found`.
///   4. **Aggregate / fan-out.** A single registry id whose intended
///      execution is to fire the matching N atomic commands in
///      sequence. Phase 2 either lands a `macro_id` for these or
///      adds client-side fan-out in the router.
///   5. **Sunroof drift.** Registry has per-verb ids; textproto has
///      a single `sunroof.ctl` with a value enum whose mapping isn't
///      ground-truthed in this repo yet. Add the `_verbValue`-style
///      bridge once the framework values are confirmed.
const _knownDartOnly = <String>{
  // 1. In-app player
  'radio.next_fav',
  'radio.pause',
  'radio.play_by_name',
  'radio.play_station',
  'radio.resume',
  'radio.stop',

  // 1b. App launcher — launches OTHER Android apps via the shell bridge
  //     (`am start` / `monkey`), never the encrypted action table. See
  //     features/apps/app_voice_dispatch.dart.
  'app.open',
  'app.search',
  'app.navigate',

  // 2. Status special-case
  'car.status',

  // 3. Binder-only (Leopard 8 IAcAirConditioner properties 131/135 +
  //    IAcSeat). No FAST equivalent in the textproto; would route
  //    through acTransact when that gets wired. seat.heat.* and
  //    seat.vent.drv have textproto entries (`heat.<pos>.level`,
  //    `vent.drv.level`) and ship `resolve:` callbacks — exempted
  //    list here only retains the genuinely binder-only entries.
  'climate.comfort_mode',
  'climate.rear_lock',
  'seat.vent.pass',
  'seat.vent.rl',
  'seat.vent.rr',

  // 4. Aggregate / fan-out — no wire entry; UI surfaces it but
  //    dispatch is pending Phase 2 macro / client fan-out.
  'window.all.open',
  'window.all.close',

  // 5. Sunroof drift — textproto has `sunroof.ctl` (value enum) but
  //    the verb→value mapping isn't ground-truthed yet.
  'sunroof.open',
  'sunroof.close',
  'sunroof.tilt',
  'sunroof.stop',
};

/// Args probes per group-templated command id. Add new entries when
/// adding a new templated command — the resolver must cover EVERY
/// element of every documented value set.
List<Map<String, dynamic>> _resolveProbeArgs(String id) {
  switch (id) {
    case 'comfort.massage':
      return [
        for (final seat in ['drv', 'co'])
          for (final field in ['mode', 'level'])
            {'seat': seat, 'field': field, 'value': 1},
      ];
    case 'comfort.massage.off':
      return [
        {'seat': 'drv'},
        {'seat': 'co'},
      ];
    case 'comfort.frag.on':
      return [
        {'level': 1},
        {'level': 2},
        {'level': 3},
      ];
    case 'comfort.frag.off':
      return [const <String, dynamic>{}];
    case 'comfort.atmos':
      return [
        {'field': 'on'},
        {'field': 'off'},
        {'field': 'bright', 'value': 50},
        {'field': 'color', 'value': 0xFF0000},
      ];
    default:
      return [const <String, dynamic>{}];
  }
}

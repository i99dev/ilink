/// In-process registry of [MiniAppFamily] instances. The single
/// place that knows which families exist on this host build —
/// `_handleCapabilities` derives its families list from here, and the
/// JS-handler registration loop in [MiniAppViewer] iterates here.
///
/// Adding family N+1 is one [register] call at app bootstrap. Nothing
/// else in the bridge layer changes.
library;

import 'mini_app_family.dart';

/// Thrown when [register] is called twice with the same `familyId`
/// or with a family that overlaps an existing op name. Caught at
/// bootstrap; signals a programmer error, not a runtime failure.
class DuplicateFamilyError extends StateError {
  DuplicateFamilyError(String familyId)
    : super('duplicate familyId: $familyId');
}

/// In-memory registry. Insertion-ordered: the JS-handler registration
/// loop fires in the order families register, so capabilities and
/// `display.subscribe` event ordering are deterministic across runs.
class BridgeFamilyRegistry {
  BridgeFamilyRegistry();

  final Map<String, MiniAppFamily> _byId = <String, MiniAppFamily>{};

  /// Add a family. Order of registration is preserved by
  /// [families] / [familyIds]. Idempotent only via tests calling
  /// [clear] first; in production, registering twice is a bug.
  void register(MiniAppFamily family) {
    if (_byId.containsKey(family.familyId)) {
      throw DuplicateFamilyError(family.familyId);
    }
    _byId[family.familyId] = family;
  }

  /// Lookup by id. Returns `null` for unknown families — the gate
  /// translates that into an `unknown_family` envelope.
  MiniAppFamily? lookup(String familyId) => _byId[familyId];

  /// All registered families in insertion order.
  Iterable<MiniAppFamily> get families => _byId.values;

  /// All registered family ids in insertion order — used by
  /// `_handleCapabilities` to publish the family list to mini-apps.
  Iterable<String> get familyIds => _byId.keys;

  /// Number of registered families. Cheap; cached via the underlying
  /// map.
  int get length => _byId.length;

  /// Test-only: drop every registration. Production code must never
  /// call this — handlers registered against the WebView still
  /// reference the cleared families.
  void clearForTests() => _byId.clear();
}

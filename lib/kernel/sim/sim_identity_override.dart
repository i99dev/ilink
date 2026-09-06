import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'iccid_imsi_generator.dart';

/// Persisted state for the SIM identity override.
///
/// The override is **app-local**: nothing here writes to a system
/// property. Apps that ask the SIM-identity reader (or any future
/// consumer in this app) get the override value when [active] is
/// true; the modem's real prop is untouched.
@immutable
class SimIdentityOverride {
  const SimIdentityOverride({
    required this.active,
    required this.current,
    required this.history,
  });

  /// When false, the reader returns the real `persist.radio.iccid`
  /// regardless of [current]. Toggled by Apply / Clear in the UI.
  final bool active;

  /// The pair the user picked, or null when nothing was ever applied.
  final GeneratedSimIdentity? current;

  /// Most-recent first; capped at [SimIdentityOverrideController.historyLimit]
  /// to keep the SharedPreferences blob small.
  final List<GeneratedSimIdentity> history;

  static const empty = SimIdentityOverride(
    active: false,
    current: null,
    history: <GeneratedSimIdentity>[],
  );

  SimIdentityOverride copyWith({
    bool? active,
    GeneratedSimIdentity? current,
    List<GeneratedSimIdentity>? history,
  }) => SimIdentityOverride(
    active: active ?? this.active,
    current: current ?? this.current,
    history: history ?? this.history,
  );

  /// Like [copyWith], but lets a caller explicitly clear [current]
  /// (which [copyWith] can't do because null defaults to "keep").
  SimIdentityOverride withCleared() =>
      SimIdentityOverride(active: false, current: null, history: history);
}

const _kPrefsKey = 'sim_identity_override.v1';

/// Persisted SharedPreferences blob shape. Wrapping `current` +
/// `history` together keeps the serialised state cohesive — a torn
/// write that drops one field can't leave the other half stale.
String _encode(SimIdentityOverride v) {
  return jsonEncode({
    'active': v.active,
    'current': v.current?.toJson(),
    'history': v.history.map((g) => g.toJson()).toList(),
  });
}

SimIdentityOverride _decode(String raw) {
  try {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final active = json['active'] as bool? ?? false;
    final currentJson = json['current'];
    final current = currentJson is Map<String, dynamic>
        ? GeneratedSimIdentity.fromJson(currentJson)
        : null;
    final historyRaw = json['history'];
    final history = <GeneratedSimIdentity>[];
    if (historyRaw is List) {
      for (final entry in historyRaw) {
        if (entry is Map<String, dynamic>) {
          final parsed = GeneratedSimIdentity.fromJson(entry);
          if (parsed != null) history.add(parsed);
        }
      }
    }
    return SimIdentityOverride(
      active: active && current != null,
      current: current,
      history: history,
    );
  } catch (_) {
    // Forward-compat: any schema change ships an empty state rather
    // than crashing the app on the first frame after upgrade.
    return SimIdentityOverride.empty;
  }
}

/// AsyncNotifier-backed Riverpod controller for the override state.
///
/// All mutations are durable — every call to [apply], [clear] and
/// [generateAndApply] writes back to SharedPreferences before
/// returning. Failure to persist is observable via [state] (it
/// will momentarily show loading, then re-emit the prior data
/// unchanged), but mutations are best-effort: an app-restart
/// concurrent with a write can lose the most-recent change. That's
/// acceptable for a diagnostic/spoof feature.
class SimIdentityOverrideController extends AsyncNotifier<SimIdentityOverride> {
  /// Last 10 generations is plenty for a "tap to re-apply" history
  /// without ballooning the SharedPreferences payload.
  static const historyLimit = 10;

  @override
  Future<SimIdentityOverride> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefsKey);
    if (raw == null) return SimIdentityOverride.empty;
    return _decode(raw);
  }

  /// Pure-Dart generator. Held as a field so tests can swap in a
  /// seeded [IccidImsiGenerator] for deterministic check-digit
  /// assertions; production uses the secure-random default.
  IccidImsiGenerator _generator = IccidImsiGenerator();

  @visibleForTesting
  set generator(IccidImsiGenerator g) => _generator = g;

  Future<void> _persist(SimIdentityOverride next) async {
    state = AsyncValue.data(next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefsKey, _encode(next));
  }

  /// Generate a fresh pair for [carrier], push it onto history, and
  /// activate it as the current override. The return value is the
  /// new entry so the UI can show "just generated" affordances
  /// (copy buttons, animation) without re-reading state.
  Future<GeneratedSimIdentity> generateAndApply(
    ChineseCarrierPreset carrier,
  ) async {
    final fresh = _generator.generate(carrier);
    final prev = state.value ?? SimIdentityOverride.empty;
    final newHistory = <GeneratedSimIdentity>[fresh, ...prev.history];
    final capped = newHistory.length > historyLimit
        ? newHistory.sublist(0, historyLimit)
        : newHistory;
    await _persist(
      prev.copyWith(active: true, current: fresh, history: capped),
    );
    return fresh;
  }

  /// Re-apply a [GeneratedSimIdentity] from history without
  /// generating new digits. Caller is responsible for passing an
  /// instance that came from [state.value!.history].
  Future<void> applyFromHistory(GeneratedSimIdentity entry) async {
    final prev = state.value ?? SimIdentityOverride.empty;
    await _persist(prev.copyWith(active: true, current: entry));
  }

  /// Disable the override but keep the chosen pair and history
  /// around so the user can re-enable without re-generating.
  Future<void> deactivate() async {
    final prev = state.value ?? SimIdentityOverride.empty;
    if (!prev.active) return;
    await _persist(prev.copyWith(active: false));
  }

  /// Wipe history + current. Used by "Reset" — both visible (UI
  /// state) and stored (SharedPreferences) go back to factory.
  Future<void> reset() async {
    await _persist(SimIdentityOverride.empty);
  }
}

final simIdentityOverrideProvider =
    AsyncNotifierProvider<SimIdentityOverrideController, SimIdentityOverride>(
      SimIdentityOverrideController.new,
    );

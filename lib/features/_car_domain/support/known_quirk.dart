/// A known-issue note attached to a [CarSupportProfile] entry, surfaced
/// in the UI **before** the user attempts the affected action so they
/// understand the limitation up-front instead of inferring it from a
/// silent failure.
///
/// Pattern adapted from Dudu Launcher Pro's per-model warning surface
/// (e.g. "some Han EV models can't fully close the windows — lock the
/// car and silence it for 5 min to recover"). Quirks are advisory,
/// not gating: they're rendered next to the relevant tile, but the
/// underlying CarCommandRouter / dispatcher decision is unchanged.
///
/// Severity drives the visual weight of the surface — `info` for
/// "behaves slightly differently", `warning` for "may not work
/// reliably; here's the workaround", `blocked` for "this combination
/// genuinely doesn't have the hardware".
library;

import 'package:flutter/foundation.dart' show immutable;

enum QuirkSeverity {
  /// Behavioural difference worth noting, no recovery needed.
  info,

  /// Action may fail intermittently; quirk message includes the
  /// workaround.
  warning,

  /// Hardware genuinely absent on this trim. Surfaces the row with
  /// the action greyed out + the quirk message as the explanation.
  blocked,
}

@immutable
class KnownQuirk {
  const KnownQuirk({
    required this.actionId,
    required this.severity,
    required this.message,
  });

  /// CarCommandRouter action id this quirk attaches to. Matches the
  /// id surface in the existing encrypted car_table — e.g.
  /// `window.fl.close`, `seat.heat.driver`, `fragrance.on`. The
  /// registry-side definitions reference these by string so renames
  /// to action ids land as broken-link compile errors here.
  final String actionId;

  final QuirkSeverity severity;

  /// User-facing message. Source-of-truth English; translated copies
  /// land in arb when each quirk reaches the matching feature's UI.
  /// Kept short — typically one sentence — so it fits next to the
  /// action's tile without forcing a wrap.
  final String message;
}

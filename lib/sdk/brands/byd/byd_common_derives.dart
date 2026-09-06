/// Pre-baked derived signals every BYD-aware surface tends to want.
/// Installs in one call; consumer gets `derived.*` names through the
/// usual `client.value` / `client.watch` / `client.freshness` API.
///
/// Centralising these here means the same composition is computed
/// **once per process** instead of being re-derived inside every tile
/// that needs the same OR / SUM. Less churn on the push hot path,
/// uniform semantics across the app, one place to fix when the source
/// catalog names change.
library;

import '../../car/client.dart';

/// Install the common BYD derives onto [client]. Returns the list of
/// handles so the caller can `dispose` them (typically never; these
/// live for the app's lifetime). Idempotent — re-calling replaces the
/// existing compute fns (CarClient.derive contract).
List<DerivedHandle> installBydCommonDerives(CarClient client) {
  return [
    // Any door open — OR of every closure (5 doors + trunk).
    client.derive(
      name: 'derived.any_door_open',
      sources: const [
        'Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR',
        'Bodywork.BODYWORK_RIGHT_HAND_FRONT_DOOR',
        'Bodywork.BODYWORK_LEFT_HAND_REAR_DOOR',
        'Bodywork.BODYWORK_RIGHT_HAND_REAR_DOOR',
        'Bodywork.BODYWORK_LUGGAGE_DOOR',
      ],
      compute: (vals) => vals.values.any((v) => v != null && v != 0) ? 1 : 0,
    ),

    // Any exterior light on — head, low/high beam, fog F/R.
    client.derive(
      name: 'derived.exterior_lights_on',
      sources: const [
        'Light.LIGHT_LOW_BEAM_LIGHT',
        'Light.LIGHT_HIGH_BEAM_LIGHT',
        'Light.LIGHT_FRONT_FOG_LIGHT',
        'Light.LIGHT_REAR_FOG_LIGHT',
      ],
      compute: (vals) => vals.values.any((v) => v != null && v != 0) ? 1 : 0,
    ),

    // Total range = EV + fuel. Either may be 0 (mode locked). Returns
    // null when both are unknown so consumers render `--` instead of
    // a misleading 0.
    client.derive(
      name: 'derived.total_range_km',
      sources: const [
        'Statistic.STATISTIC_ELEC_DRIVING_RANGE',
        'Statistic.STATISTIC_FUEL_DRIVING_RANGE',
      ],
      compute: (vals) {
        final ev = vals['Statistic.STATISTIC_ELEC_DRIVING_RANGE'];
        final fuel = vals['Statistic.STATISTIC_FUEL_DRIVING_RANGE'];
        if (ev == null && fuel == null) return null;
        return (ev ?? 0) + (fuel ?? 0);
      },
    ),

    // Cabin "comfortable" — temperature inside the 18–26°C band.
    // Returns null when the cabin temp signal hasn't arrived yet.
    client.derive(
      name: 'derived.cabin_comfortable',
      sources: const ['Ac.AC_TEMP_INSIDE'],
      compute: (vals) {
        final t = vals['Ac.AC_TEMP_INSIDE'];
        if (t == null) return null;
        return (t >= 18 && t <= 26) ? 1 : 0;
      },
    ),

    // Driver door specifically (often special-cased in security UX).
    client.derive(
      name: 'derived.driver_door_open',
      sources: const ['Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR'],
      compute: (vals) {
        final v = vals['Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR'];
        if (v == null) return null;
        return v == 0 ? 0 : 1;
      },
    ),
  ];
}

/// BYD signal catalog — single source of truth.
///
/// Every brand-neutral signal name the bridge exposes lives here,
/// paired with its underlying BYD framework name and metadata
/// (description, units, range, write action, 3D-friendly flag).
///
/// **Distinct from [CarCatalog]** at `lib/sdk/car/catalog.dart`:
///
/// - [CarCatalog] is the brand-internal one (13k+ entries with
///   integer feature ids). Used by the SDK's reflection layer.
/// - [BydPublicCatalog] (this file) is what crosses the bridge.
///   1000+ brand-neutral names (`door_lf`, `ac_target_temp`) with
///   UI metadata. No integer ids, no framework names, no
///   brand-specific terminology leak through the bridge.
///
/// **Legacy exports.** [bydStatusLabelToCatalog] and [bydBootWarmSet]
/// are kept as re-exports — every call site that imports them from
/// `byd_status_labels.dart` continues to work through the shim
/// `byd_status_labels.dart` which re-exports both symbols from here.
///
/// **Adding a brand later** (NIO, Geely) = ship a `<brand>_catalog.dart`
/// that defines the same `_Sig` shape; the bridge layer is brand-
/// agnostic.
library;

import '../../car/public_catalog.dart';

/// One catalog row. The brand-neutral [name] is the bridge wire key;
/// [framework] is the BYD framework name resolved by
/// `BydAutoFeatureIdsCatalog` on the Kotlin side.
class _Sig {
  const _Sig(
    this.name,
    this.framework, {
    this.description,
    this.units,
    this.category,
    this.writeable = false,
    this.writeAction,
    this.wireActionId,
    this.binderOnly = false,
    this.threeD = false,
    this.range,
  });

  final String name;
  final String framework;
  final String? description;
  final String? units;

  /// Coarse UI grouping. When `null`, [_inferCategory] derives it
  /// from the [name] prefix.
  final String? category;
  final bool writeable;

  /// Mini-app-facing action name. Brand-neutral, verb-suffixed
  /// (`climate.power.toggle`, `seat.heat.drv.set`). This is what the
  /// catalog ships to mini-apps via `PublicCatalogEntry.writeActionId`
  /// and what they pass to `car.command()`.
  ///
  /// **Note** — Until Phase 2 of the command-methodology rename
  /// ships, this string is NOT what the daemon's UnitDispatcher
  /// recognises. The actual wire-known action id is [wireActionId];
  /// the host translates [writeAction] → [wireActionId] for mini-app
  /// dispatches.
  final String? writeAction;

  /// Daemon-known wire action_id from
  /// `.secrets/car_table/car_table.textproto`. The host's
  /// `CarCommandRouter` dispatches THIS string to the daemon; the
  /// daemon looks it up in the encrypted action table and binds to
  /// the matching `feature_name` (which equals [framework] for FAST
  /// actions on the BYD AC / BODY / SEAT device buses).
  ///
  /// **Required invariant**:
  /// `wireActionId` MUST appear as an `action_id` in the textproto.
  /// `test/sdk/brands/byd/byd_catalog_wire_parity_test.dart` enforces
  /// this at CI time; a populated entry that drifts away from a wire
  /// id fails the build.
  ///
  /// `null` means one of:
  ///   * The signal is read-only ([writeable] = false).
  ///   * The signal is writeable but routes through a non-FAST path
  ///     (binder / acTransact / aspirational future API).
  ///   * Phase 4 hasn't backfilled it yet — the registry domain file
  ///     still owns the resolve mapping.
  ///
  /// Phase 2 deletes this field entirely (rename closes the gap so
  /// `writeAction` IS the wire id); Phase 4 reverses the dependency
  /// — registry reads ids FROM here instead of declaring its own.
  final String? wireActionId;

  /// True when the signal is writeable via a non-FAST path (Android
  /// binder, `acTransact`, or another unit_action interpreter inside
  /// the daemon) — NOT via a textproto `fast_actions { action_id }`
  /// row. The parity test exempts these from the
  /// "writeable-without-wireActionId" TODO list because there is
  /// nothing to backfill on the wire side. They still surface in the
  /// public catalog with [writeable] = true so mini-apps see them; the
  /// host's `CarCommandRouter` is expected to route them via the
  /// binder transport rather than `UnitDispatcher.fast`.
  final bool binderOnly;

  final bool threeD;
  final IntRange? range;
}

/// Category prefix table. Order matters — longer prefixes first.
const _categoryByPrefix = <(String, String)>[
  ('adas_', 'adas'),
  ('audio_', 'media'),
  ('window', 'doors'),
  ('door', 'doors'),
  ('lock', 'doors'),
  ('child_lock', 'doors'),
  ('hood', 'doors'),
  ('trunk', 'doors'),
  ('moon_roof', 'doors'),
  ('sunroof', 'doors'),
  ('sunshade', 'doors'),
  ('fuel_cap', 'doors'),
  ('rain_auto', 'doors'),
  ('mirror_', 'doors'),
  ('ac_', 'climate'),
  ('seat_heat', 'climate'),
  ('seat_vent', 'climate'),
  ('headlight', 'lights'),
  ('low_beam', 'lights'),
  ('high_beam', 'lights'),
  ('front_fog', 'lights'),
  ('rear_fog', 'lights'),
  ('turn_', 'lights'),
  ('drl', 'lights'),
  ('foot_light', 'lights'),
  ('side_light', 'lights'),
  ('stalk_', 'lights'),
  ('inside_light', 'lights'),
  ('light_', 'lights'),
  ('hazard', 'lights'),
  ('reverse_light', 'lights'),
  ('brake_light', 'lights'),
  ('atmos_', 'cabin'),
  ('massage_', 'cabin'),
  ('fragrance', 'cabin'),
  ('perfume_', 'cabin'),
  ('seat_pos_', 'cabin'),
  ('seat_back_', 'cabin'),
  ('refrigerator', 'cabin'),
  ('belt_', 'safety'),
  ('battery', 'propulsion'),
  ('fuel_pct', 'propulsion'),
  ('range_', 'propulsion'),
  ('ev_mode', 'propulsion'),
  ('hev_mode', 'propulsion'),
  ('energy_', 'propulsion'),
  ('regen_', 'propulsion'),
  ('engine_', 'propulsion'),
  ('motor_', 'propulsion'),
  ('voice_sim', 'propulsion'),
  ('gearbox_', 'propulsion'),
  ('gear_', 'propulsion'),
  ('epb_', 'propulsion'),
  ('park_brake', 'propulsion'),
  ('water_temp', 'propulsion'),
  ('hv_', 'propulsion'),
  ('drive_mode', 'propulsion'),
  ('speed_', 'dynamics'),
  ('accelerator_', 'dynamics'),
  ('brake_', 'dynamics'),
  ('cruise_', 'dynamics'),
  ('avh_', 'dynamics'),
  ('steering_', 'dynamics'),
  ('yaw_', 'dynamics'),
  ('slope', 'dynamics'),
  ('chg_', 'charging'),
  ('charge_', 'charging'),
  ('appointment_', 'charging'),
  ('wiper_', 'safety'),
  ('washer_', 'safety'),
  ('sensor_', 'sensors'),
  ('pm25_', 'sensors'),
  ('co2_', 'sensors'),
  ('aqs_', 'sensors'),
  ('rain_sensor', 'sensors'),
  ('humidity_', 'sensors'),
  ('tpms_', 'safety'),
  ('radar_', 'safety'),
  ('airbag', 'safety'),
  ('collision', 'safety'),
  ('warn_', 'safety'),
  ('horn', 'safety'),
  ('stat_', 'statistics'),
  ('trip_', 'statistics'),
  ('set_', 'settings'),
  ('ota_', 'system'),
  ('time_', 'system'),
  ('power_', 'system'),
  ('hud_', 'system'),
  ('screen_', 'system'),
  ('gb_', 'propulsion'),
];

String _inferCategory(String name) {
  for (final pair in _categoryByPrefix) {
    if (name.startsWith(pair.$1)) return pair.$2;
  }
  return 'system';
}

/// Humanise `door_lf` -> `"Door LF"`.
String _humanise(String name) {
  return name
      .split('_')
      .map(
        (s) => s.isEmpty
            ? s
            : (s.length <= 2
                  ? s.toUpperCase()
                  : s[0].toUpperCase() + s.substring(1)),
      )
      .join(' ');
}

/// Source-of-truth catalog rows. Adding a new signal = one row.
const _entries = <_Sig>[
  // ── Doors / locks ─────────────────────────────────────────────
  _Sig(
    'door_lock',
    'Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT',
    description: 'Master door-lock state',
    writeable: true,
    writeAction: 'door.lock.all',
    wireActionId: 'door.lock',
  ),
  _Sig(
    'door_lf',
    'Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR',
    description: 'Front-left door state (0 closed, 1 open)',
    threeD: true,
  ),
  _Sig(
    'door_rf',
    'Bodywork.BODYWORK_RIGHT_HAND_FRONT_DOOR',
    description: 'Front-right door state (0 closed, 1 open)',
    threeD: true,
  ),
  _Sig(
    'door_lr',
    'Bodywork.BODYWORK_LEFT_HAND_REAR_DOOR',
    description: 'Rear-left door state (0 closed, 1 open)',
    threeD: true,
  ),
  _Sig(
    'door_rr',
    'Bodywork.BODYWORK_RIGHT_HAND_REAR_DOOR',
    description: 'Rear-right door state (0 closed, 1 open)',
    threeD: true,
  ),
  _Sig(
    'trunk',
    'Bodywork.BODYWORK_LUGGAGE_DOOR',
    description: 'Trunk / tailgate state (0 closed, 1 open)',
    threeD: true,
  ),
  _Sig(
    'lock_lf',
    'Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT',
    description: 'Front-left door lock state',
    writeable: true,
    writeAction: 'door.lock.fl',
    // Per-door binder write; FAST wire only has the bulk `door.lock`
    // (BODYWORK_FOUR_DOOR_SET) action. Same for the other three.
    binderOnly: true,
  ),
  _Sig(
    'lock_rf',
    'Door.DOOR_LOCK_COMMAND_AREA_RIGHT_FRONT',
    description: 'Front-right door lock state',
    writeable: true,
    writeAction: 'door.lock.fr',
    binderOnly: true,
  ),
  _Sig(
    'lock_lr',
    'Door.DOOR_LOCK_COMMAND_AREA_LEFT_REAR',
    description: 'Rear-left door lock state',
    writeable: true,
    writeAction: 'door.lock.rl',
    binderOnly: true,
  ),
  _Sig(
    'lock_rr',
    'Door.DOOR_LOCK_COMMAND_AREA_RIGHT_REAR',
    description: 'Rear-right door lock state',
    writeable: true,
    writeAction: 'door.lock.rr',
    binderOnly: true,
  ),
  _Sig(
    'lock_back',
    'Door.DOOR_LOCK_COMMAND_AREA_BACK',
    description: 'Tailgate lock state',
  ),
  _Sig(
    'child_lock_l',
    'Door.DOOR_LOCK_COMMAND_AREA_CHILDLOCK_LEFT',
    description: 'Rear-left child lock (0 unlocked, 1 locked)',
  ),
  _Sig(
    'child_lock_r',
    'Door.DOOR_LOCK_COMMAND_AREA_CHILDLOCK_RIGHT',
    description: 'Rear-right child lock (0 unlocked, 1 locked)',
  ),
  _Sig(
    'hood',
    'Bodywork.BODYWORK_HOOD',
    description: 'Hood / bonnet state (0 closed, 1 open)',
    threeD: true,
  ),
  _Sig(
    'fuel_cap',
    'Bodywork.BODYWORK_FUEL_TANK_CAP',
    description: 'Fuel filler cap state (0 closed, 1 open)',
    threeD: true,
  ),
  _Sig(
    'window_lf',
    'Bodywork.BODYWORK_LEFT_FRONT_WINDOW',
    description: 'Front-left window state (0 closed, 1 open)',
    threeD: true,
  ),
  _Sig(
    'window_rf',
    'Bodywork.BODYWORK_RIGHT_FRONT_WINDOW',
    description: 'Front-right window state (0 closed, 1 open)',
    threeD: true,
  ),
  _Sig(
    'window_lr',
    'Bodywork.BODYWORK_LEFT_REAR_WINDOW',
    description: 'Rear-left window state (0 closed, 1 open)',
    threeD: true,
  ),
  _Sig(
    'window_rr',
    'Bodywork.BODYWORK_RIGHT_REAR_WINDOW',
    description: 'Rear-right window state (0 closed, 1 open)',
    threeD: true,
  ),
  _Sig(
    'window_lf_pct',
    'Bodywork.BODYWORK_WINDOW_LEFT_FRONT_PERCENT',
    description: 'Front-left window position 0-100%',
    units: 'percent',
    range: IntRange(0, 100),
    threeD: true,
  ),
  _Sig(
    'window_rf_pct',
    'Bodywork.BODYWORK_WINDOW_RIGHT_FRONT_PERCENT',
    description: 'Front-right window position 0-100%',
    units: 'percent',
    range: IntRange(0, 100),
    threeD: true,
  ),
  _Sig(
    'window_lr_pct',
    'Bodywork.BODYWORK_WINDOW_LEFT_REAR_PERCENT',
    description: 'Rear-left window position 0-100%',
    units: 'percent',
    range: IntRange(0, 100),
    threeD: true,
  ),
  _Sig(
    'window_rr_pct',
    'Bodywork.BODYWORK_WINDOW_RIGHT_REAR_PERCENT',
    description: 'Rear-right window position 0-100%',
    units: 'percent',
    range: IntRange(0, 100),
    threeD: true,
  ),
  _Sig(
    'moon_roof',
    'Bodywork.BODYWORK_MOON_ROOF',
    description: 'Sunroof / moon-roof state (0 closed, 1 open)',
    threeD: true,
  ),
  _Sig(
    'moon_roof_pct',
    'Bodywork.BODYWORK_MOON_ROOF_OPEN_PERCENT',
    description: 'Sunroof position 0-100%',
    units: 'percent',
    range: IntRange(0, 100),
    threeD: true,
  ),
  _Sig(
    'sunshade',
    'Bodywork.BODYWORK_SUNSHADE_PANEL',
    description: 'Sunshade panel state (0 closed, 1 open)',
    threeD: true,
  ),
  _Sig(
    'sunshade_pct',
    'Bodywork.BODYWORK_SUNSHADE_PANEL_PERCENT',
    description: 'Sunshade position 0-100%',
    units: 'percent',
    range: IntRange(0, 100),
    threeD: true,
  ),
  _Sig(
    'sunroof_state',
    'Bodywork.BODYWORK_SUNROOF_STATE',
    description: 'Detailed sunroof state enum',
  ),
  _Sig(
    'sunroof_position',
    'Bodywork.BODYWORK_SUNROOF_POSITION',
    description: 'Sunroof absolute position raw',
  ),
  _Sig(
    'rain_auto_close',
    'Bodywork.BODYWORK_CLOSE_WINDOW_FOR_RAIN_ONLINE',
    description: 'Auto-close windows on rain (0 off, 1 on)',
  ),

  // ── Climate ───────────────────────────────────────────────────
  _Sig(
    'ac_power',
    'Ac.AC_POWER_STATE',
    description: 'AC power state (0 off, 1 on)',
    writeable: true,
    writeAction: 'climate.power.toggle',
    wireActionId: 'climate.power',
  ),
  _Sig(
    'ac_fan',
    'Ac.AC_WIND_LEVEL',
    description: 'AC fan speed level (0 off, 1-7 ascending)',
    range: IntRange(0, 7),
    writeable: true,
    writeAction: 'climate.fan.set',
    wireActionId: 'climate.fan',
  ),
  _Sig(
    'ac_wind_mode',
    'Ac.AC_WIND_MODE',
    description:
        'AC wind distribution mode (1=face, 2=face+feet, '
        '3=feet, 4=defrost+feet)',
    range: IntRange(1, 4),
    writeable: true,
    writeAction: 'climate.mode.set',
    wireActionId: 'climate.mode',
  ),
  _Sig(
    'ac_cycle',
    'Ac.AC_CYCLE_MODE',
    description: 'AC recirculation mode (0 fresh, 1 recirculate)',
    writeable: true,
    writeAction: 'climate.cycle.toggle',
    wireActionId: 'climate.cycle',
  ),
  _Sig(
    'ac_target_temp',
    'Ac.AC_TEMP_MAIN',
    description:
        'AC target temperature, raw celsius integer (verified on '
        'DiLink 5.1 / Leopard 8 - value 17 = 17 C, no scaling)',
    units: 'celsius',
    range: IntRange(16, 32),
    writeable: true,
    writeAction: 'climate.temp.set',
    wireActionId: 'climate.temp',
  ),
  _Sig(
    'ac_cabin_temp',
    'Ac.AC_TEMP_INSIDE',
    description: 'Cabin temperature, raw celsius integer',
    units: 'celsius',
  ),
  _Sig(
    'ac_temp_out',
    'Instrument.INSTRUMENT_DD_OUT_TEMP',
    description: 'Outside ambient temperature, raw celsius integer',
    units: 'celsius',
  ),
  _Sig(
    'ac_ctrl_mode',
    'Ac.AC_CTRL_MODE',
    description: 'AC control mode (manual / auto / eco)',
  ),
  _Sig(
    'ac_compressor',
    'Ac.AC_COMPRESSOR_MODE',
    description: 'AC compressor state (0 off, 1 on)',
    writeable: true,
    writeAction: 'climate.compressor.toggle',
    wireActionId: 'climate.compressor',
  ),
  _Sig(
    'ac_target_temp_co',
    'Ac.AC_TEMP_DEPUTY',
    description: 'AC target temperature for front passenger',
    units: 'celsius',
    range: IntRange(16, 32),
  ),
  _Sig(
    'ac_target_temp_rear',
    'Ac.AC_TEMP_REAR',
    description: 'AC target temperature for rear zone',
    units: 'celsius',
    range: IntRange(16, 32),
  ),
  _Sig(
    'ac_temp_unit',
    'Ac.AC_TEMPERATURE_UNIT',
    description: 'Temperature unit (0 celsius, 1 fahrenheit)',
  ),
  _Sig(
    'ac_defrost_f',
    'Ac.AC_DEFROST_FRONT_STATE',
    description: 'Front windscreen defrost state (0 off, 1 on)',
    writeable: true,
    writeAction: 'climate.defrost.front.toggle',
    wireActionId: 'climate.defrost_f',
  ),
  _Sig(
    'ac_defrost_r',
    'Ac.AC_DEFROST_REAR_STATE',
    description: 'Rear windscreen defrost state (0 off, 1 on)',
    writeable: true,
    writeAction: 'climate.defrost.rear.toggle',
    wireActionId: 'climate.defrost_r',
  ),
  _Sig(
    'ac_max_cool',
    'Ac.AC_MAX_COOLING_STATE',
    description: 'Max cooling mode (0 off, 1 on)',
    writeable: true,
    writeAction: 'climate.max_cool.toggle',
    wireActionId: 'climate.max_cool',
  ),
  _Sig(
    'ac_max_hot',
    'Ac.AC_MAX_HEATING_STATE',
    description: 'Max heating mode (0 off, 1 on)',
    writeable: true,
    writeAction: 'climate.max_hot.toggle',
    wireActionId: 'climate.max_hot',
  ),
  _Sig(
    'ac_vent',
    'Ac.AC_VENTILATION_STATE',
    description: 'AC ventilation mode state',
  ),
  _Sig(
    'ac_rear_power',
    'Ac.AC_REAR_POWER_STATE',
    description: 'Rear AC power state (0 off, 1 on)',
  ),
  _Sig(
    'ac_temp_separate',
    'Ac.AC_TEMPCTRL_SEPARATE_STATE',
    description: 'Dual-zone temperature split (0 sync, 1 independent)',
  ),
  _Sig(
    'ac_quick_clean',
    'Ac.AC_QUICK_CLEAN_AIR',
    description: 'Quick-clean cabin air mode',
  ),
  _Sig(
    'ac_auto_clean',
    'Ac.AC_AUTO_CLEAN_AIR',
    description: 'Auto-clean cabin air mode',
  ),

  // ── Lights ────────────────────────────────────────────────────
  _Sig(
    'headlight',
    'Instrument.INSTRUMENT_SMART_KEY_SYS_WARN_LIGHT',
    description: 'Smart-key system warn light (proxy for headlight power)',
  ),
  _Sig(
    'low_beam',
    'Light.LIGHT_LOW_BEAM_LIGHT',
    description: 'Low-beam headlight state (0 off, 1 on)',
    threeD: true,
    writeable: true,
    writeAction: 'lights.lowbeam.toggle',
    wireActionId: 'light.head.on',
  ),
  _Sig(
    'high_beam',
    'Light.LIGHT_HIGH_BEAM_LIGHT',
    description: 'High-beam headlight state (0 off, 1 on)',
    threeD: true,
    writeable: true,
    writeAction: 'lights.highbeam.toggle',
    wireActionId: 'light.head',
  ),
  _Sig(
    'front_fog',
    'Light.LIGHT_FRONT_FOG_LIGHT',
    description: 'Front fog light state (0 off, 1 on)',
    threeD: true,
    writeable: true,
    writeAction: 'lights.fog.front.toggle',
    wireActionId: 'light.fog_f',
  ),
  _Sig(
    'rear_fog',
    'Light.LIGHT_REAR_FOG_LIGHT',
    description: 'Rear fog light state (0 off, 1 on)',
    threeD: true,
    writeable: true,
    writeAction: 'lights.fog.rear.toggle',
    wireActionId: 'light.fog_r',
  ),
  _Sig(
    'turn_left',
    'Light.LIGHT_LEFT_TURN_SIGNAL_LIGHT',
    description: 'Left turn signal blink state (0 off, 1 on)',
    threeD: true,
    writeable: true,
    writeAction: 'lights.turn_left.toggle',
    wireActionId: 'light.turn_left',
  ),
  _Sig(
    'turn_right',
    'Light.LIGHT_RIGHT_TURN_SIGNAL_LIGHT',
    description: 'Right turn signal blink state (0 off, 1 on)',
    threeD: true,
    writeable: true,
    writeAction: 'lights.turn_right.toggle',
    wireActionId: 'light.turn_right',
  ),
  _Sig(
    'turn_signal',
    'Light.LIGHT_TURN_SIGNAL_LIGHT',
    description:
        'Combined turn-signal state (driver-side bit + passenger-side bit)',
    threeD: true,
  ),
  _Sig(
    'drl',
    'Light.LIGHT_DAY_RUNNING_LIGHT_AUTO_STATE',
    description: 'Daytime running light auto state',
    threeD: true,
  ),
  _Sig(
    'foot_light',
    'Light.LIGHT_FOOT_LIGHT',
    description: 'Foot-well lights state',
  ),
  _Sig(
    'side_light',
    'Light.LIGHT_SIDE_LIGHT',
    description: 'Side / parking lights state',
  ),
  _Sig(
    'stalk_l',
    'Light.LIGHT_LEFT_TURN_SIGNAL_LIGHT_SWITCH_STATE',
    description: 'Left turn-signal stalk position',
  ),
  _Sig(
    'stalk_r',
    'Light.LIGHT_RIGHT_TURN_SIGNAL_LIGHT_SWITCH_STATE',
    description: 'Right turn-signal stalk position',
  ),

  // ── Powertrain / dynamics ─────────────────────────────────────
  _Sig(
    'battery_pct',
    'Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE',
    description: 'Traction battery state of charge',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'fuel_pct',
    'Statistic.STATISTIC_FUEL_PERCENTAGE',
    description: 'Fuel tank level',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'range_ev_km',
    'Statistic.STATISTIC_ELEC_DRIVING_RANGE',
    description: 'Estimated remaining EV range',
    units: 'km',
  ),
  _Sig(
    'range_fuel_km',
    'Statistic.STATISTIC_FUEL_DRIVING_RANGE',
    description: 'Estimated remaining fuel range',
    units: 'km',
  ),
  _Sig(
    'battery_wh',
    'Statistic.STATISTIC_REMAINING_BATTERY_POWER',
    description: 'Remaining battery energy',
    units: 'kwh',
  ),
  _Sig(
    'ev_mode',
    'Instrument.INSTRUMENT_EV_MODE_INDICATORE',
    description: 'EV-mode indicator (pure-electric)',
  ),
  _Sig(
    'hev_mode',
    'Instrument.INSTRUMENT_HEV_MODE_INDICATORE',
    description: 'HEV-mode indicator (hybrid)',
  ),
  _Sig(
    'energy_state',
    'Energy.ENERGY_STATE',
    description: 'Energy system state',
  ),
  _Sig(
    'regen_power',
    'Energy.ENERGY_POWER_GENERATION_VALUE',
    description: 'Regenerative braking power generated',
    units: 'kw',
  ),
  _Sig(
    'engine_rpm',
    'Engine.ENGINE_SPEED',
    description: 'Engine speed',
    units: 'rpm',
  ),
  _Sig(
    'engine_rpm_gb',
    'Engine.ENGINE_SPEED_GB',
    description: 'Engine speed (GB platform)',
    units: 'rpm',
  ),
  _Sig(
    'engine_power',
    'Engine.ENGINE_POWER',
    description: 'Engine output power',
    units: 'kw',
  ),
  _Sig(
    'engine_disp',
    'Engine.ENGINE_DISPLACEMENT',
    description: 'Engine displacement (litres x 10 on some ROMs)',
  ),
  _Sig(
    'motor_f_rpm',
    'Engine.ENGINE_FRONT_MOTOR_SPEED',
    description: 'Front motor speed',
    units: 'rpm',
    threeD: true,
  ),
  _Sig(
    'motor_r_rpm',
    'Engine.ENGINE_REAR_MOTOR_SPEED',
    description: 'Rear motor speed',
    units: 'rpm',
    threeD: true,
  ),
  _Sig(
    'motor_f_torque',
    'Engine.ENGINE_FRONT_MOTOR_TORQUE',
    description: 'Front motor torque',
  ),
  _Sig(
    'motor_r_torque',
    'Engine.ENGINE_REAR_MOTOR_TORQUE_F',
    description: 'Rear motor torque',
  ),
  _Sig(
    'voice_sim',
    'Engine.ENGINE_VOICE_SIMULATOR_STATE',
    description: 'Engine voice simulator state',
  ),
  _Sig(
    'voice_sim_source',
    'Engine.ENGINE_SIMULATOR_SOURCE_TYPE',
    description: 'Engine voice simulator source type',
  ),
  _Sig(
    'gearbox_type',
    'Gearbox.GEARBOX_TYPE',
    description: 'Gearbox type enum',
  ),
  _Sig(
    'gearbox_auto_mode',
    'Gearbox.GEARBOX_AUTO_MODE_TYPE',
    description: 'Automatic gearbox sub-mode',
  ),
  _Sig(
    'gear_manual',
    'Gearbox.GEARBOX_MANUAL_MODE_LEVEL',
    description: 'Manual gear level',
  ),
  _Sig(
    'epb_state',
    'Gearbox.GEARBOX_EPB_STATE',
    description: 'Electronic parking brake state (0 released, 1 engaged)',
  ),
  _Sig(
    'park_brake',
    'Gearbox.GEARBOX_PARK_BRAKE_SWITCH',
    description: 'Park-brake switch state',
  ),
  _Sig(
    'water_temp',
    'Statistic.STATISTIC_WATER_TEMPERATURE',
    description: 'Coolant / water temperature',
    units: 'celsius',
  ),
  _Sig(
    'speed_kmh',
    'Statistic.STATISTIC_SPEED_SIG_VDIS',
    description: 'Vehicle speed (whole-vehicle, m/s x 100 on some ROMs)',
    units: 'km/h',
    threeD: true,
  ),
  _Sig(
    'accelerator_pct',
    'Speed.SPEED_ACCELERATOR_S',
    description: 'Accelerator pedal position',
    units: 'percent',
    range: IntRange(0, 100),
    threeD: true,
  ),
  _Sig(
    'brake_pct',
    'Speed.SPEED_BRAKE_S',
    description: 'Brake pedal position',
    units: 'percent',
    range: IntRange(0, 100),
    threeD: true,
  ),
  _Sig(
    'cruise_set_speed',
    'Speed.SPEED_AUTO_SPEED',
    description: 'Cruise control set speed',
    units: 'km/h',
  ),
  _Sig(
    'avh_state',
    'Adas.ADAS_AVH_STATE',
    description: 'Auto vehicle hold state',
  ),

  // ── Charging ──────────────────────────────────────────────────
  _Sig(
    'chg_cap_ac',
    'Charging.CHARGING_CAP_STATE_AC',
    description: 'AC charging port cap state (0 closed, 1 open)',
  ),
  _Sig(
    'chg_cap_dc',
    'Charging.CHARGING_CAP_STATE_DC',
    description: 'DC charging port cap state (0 closed, 1 open)',
  ),
  _Sig(
    'chg_capacity',
    'Charging.CHARGING_CAPACITY',
    description: 'Reported charging capacity',
    units: 'kwh',
  ),
  _Sig(
    'chg_power',
    'Charging.CHARGING_POWER',
    description: 'Current charging power',
    units: 'kw',
  ),
  _Sig(
    'chg_work_state',
    'Charging.CHARGING_CHARGER_WORK_STATE',
    description: 'Charger work state - enum: idle / charging / fault',
  ),
  _Sig(
    'chg_eta_h',
    'Charging.CHARGING_FULL_REST_HOUR',
    description: 'Time to full charge - hours component',
    units: 'hours',
  ),
  _Sig(
    'chg_eta_m',
    'Charging.CHARGING_FULL_REST_MINUTE',
    description: 'Time to full charge - minutes component',
    units: 'minutes',
    range: IntRange(0, 59),
  ),
  _Sig(
    'chg_soc_save',
    'Charging.CHARGING_SOC_SAVE_SWITCH',
    description: 'Battery SoC-save switch',
  ),
  _Sig(
    'chg_target_soc',
    'Setting.SET_DR_SOC_TARGET',
    description: 'Target charging SoC',
    units: 'percent',
    range: IntRange(0, 100),
    writeable: true,
    writeAction: 'charging.target_soc.set',
  ),
  _Sig(
    'chg_energy_fb',
    'Setting.SET_DR_ENERGY_FB',
    description: 'Energy feedback / regen level',
  ),
  _Sig(
    'chg_wireless_fitted',
    'Charging.CHARGING_HAS_CHARGE_WIRELESS_CHARGING',
    description: 'Wireless charging hardware present (0 no, 1 yes)',
  ),
  _Sig(
    'chg_wireless_on',
    'Charging.CHARGING_CHARGE_WIRELESS_CHARGING_SWITCH',
    description: 'Wireless charging switch state',
  ),
  _Sig(
    'chg_connect_state',
    'Charging.CHARGING_CHARGER_CONNECT_STATE',
    description: 'Charger cable connect state (0 disconnected, 1 connected)',
  ),
  _Sig(
    'chg_fault_state',
    'Charging.CHARGING_CHARGER_FAULT_STATE',
    description: 'Charger fault state - enum: 0 ok, non-zero fault code',
  ),
  _Sig(
    'chg_battery_volt',
    'Charging.CHARGING_CHARGE_BATTERY_VOLT',
    description: 'Pack voltage seen by the charger',
    units: 'volts',
  ),
  _Sig(
    'chg_current',
    'Charging.CHARGING_CHARGE_CURRENT',
    description: 'Charging current at the BMS',
    units: 'amps',
  ),
  _Sig(
    'chg_ac_current',
    'Charging.CHARGING_AC_CHARGING_CURRENT',
    description: 'AC charging current (where applicable)',
    units: 'amps',
  ),

  // ── BMS / battery health ──────────────────────────────────────
  _Sig(
    'battery_capacity',
    'Bodywork.BODYWORK_BATTERY_CAPACITY',
    description: 'Total traction battery capacity',
    units: 'kwh',
  ),
  _Sig(
    'battery_voltage_level',
    'Bodywork.BODYWORK_BATTERY_VOLTAGE_LEVEL',
    description: 'Pack nominal voltage level (HV class indicator)',
    units: 'volts',
  ),
  _Sig(
    'battery_max_chg_kw',
    'Statistic.STATISTIC_MAX_CHARGE_POWER_ALLOW',
    description: 'Max charge power the BMS will accept right now',
    units: 'kw',
  ),
  _Sig(
    'battery_max_dis_kw',
    'Statistic.STATISTIC_MAX_DISCHARGE_POWER_ALLOW',
    description: 'Max discharge power the BMS will deliver right now',
    units: 'kw',
  ),
  _Sig(
    'battery_available_power',
    'Statistic.STATISTIC_BATTERY_AVAILABLE_POWER',
    description: 'Available pack power - temp + SoC + age-adjusted',
    units: 'kw',
  ),
  _Sig(
    'battery_blade_coolant_life',
    'Bodywork.BODY_BLADE_BATTERY_COOLANT_LIFE',
    description: 'Remaining service life of the Blade battery coolant',
    units: 'days',
  ),

  // ── Seats / belts ─────────────────────────────────────────────
  _Sig(
    'seat_heat_drv',
    'Ac.AC_MAIN_DRIVE_SEAT_HEATING_LEVEL',
    description: 'Driver seat heating level (0 off, 1-3 ascending)',
    range: IntRange(0, 3),
    writeable: true,
    writeAction: 'seat.heat.drv.set',
    wireActionId: 'seat.heat.drv',
  ),
  _Sig(
    'seat_heat_pass',
    'Ac.AC_PASSENGER_SEAT_HEATING_LEVEL',
    description: 'Passenger seat heating level (0 off, 1-3 ascending)',
    range: IntRange(0, 3),
    writeable: true,
    writeAction: 'seat.heat.pass.set',
    wireActionId: 'seat.heat.pass',
  ),
  _Sig(
    'seat_heat_rl',
    'Ac.AC_REAR_LEFT_SEAT_HEATING_LEVEL',
    description: 'Rear-left seat heating level (0 off, 1-3 ascending)',
    range: IntRange(0, 3),
    writeable: true,
    writeAction: 'seat.heat.rl.set',
    wireActionId: 'seat.heat.rl',
  ),
  _Sig(
    'seat_heat_rr',
    'Ac.AC_REAR_RIGHT_SEAT_HEATING_LEVEL',
    description: 'Rear-right seat heating level (0 off, 1-3 ascending)',
    range: IntRange(0, 3),
    writeable: true,
    writeAction: 'seat.heat.rr.set',
    wireActionId: 'seat.heat.rr',
  ),
  _Sig(
    'seat_vent_drv',
    'Ac.AC_MAIN_DRIVE_SEAT_VENTILATING_LEVEL',
    description: 'Driver seat ventilation level (0 off, 1-3 ascending)',
    range: IntRange(0, 3),
    writeable: true,
    writeAction: 'seat.vent.drv.set',
    wireActionId: 'seat.vent.drv',
  ),
  _Sig(
    'seat_vent_pass',
    'Ac.AC_PASSENGER_SEAT_VENTILATING_LEVEL',
    description: 'Passenger seat ventilation level (0 off, 1-3 ascending)',
    range: IntRange(0, 3),
    writeable: true,
    writeAction: 'seat.vent.pass.set',
    // IAcSeat binder path. No FAST wire row on Leopard 8 — see
    // lib/features/_car_domain/domain/seats.dart for the bare-const
    // declaration that dispatches via the binder transport.
    binderOnly: true,
  ),
  _Sig(
    'seat_vent_rl',
    'Ac.AC_REAR_LEFT_SEAT_VENTILATING_LEVEL',
    description: 'Rear-left seat ventilation level',
    range: IntRange(0, 3),
  ),
  _Sig(
    'seat_vent_rr',
    'Ac.AC_REAR_RIGHT_SEAT_VENTILATING_LEVEL',
    description: 'Rear-right seat ventilation level',
    range: IntRange(0, 3),
  ),
  _Sig(
    'belt_main',
    'Safety.SAFETY_BELT_COMMAND_AREA_MAIN',
    description: 'Driver seat belt state (0 unbuckled, 1 buckled)',
  ),
  _Sig(
    'belt_deputy',
    'Safety.SAFETY_BELT_COMMAND_AREA_DEPUTY',
    description: 'Front passenger seat belt state',
  ),
  _Sig(
    'belt_row_l',
    'Setting.SETTING_LEFT_REAR_ROW_SAFETYBELT_STATUS',
    description: 'Rear-left seat belt state',
  ),
  _Sig(
    'belt_row_mid',
    'Setting.SETTING_CENTER_REAR_ROW_SAFETYBELT_STATUS',
    description: 'Rear-centre seat belt state',
  ),
  _Sig(
    'belt_row_r',
    'Safety.SAFETY_BELT_COMMAND_AREA_SECOND_ROW_SEAT_RIGHT',
    description: 'Rear-right seat belt state',
  ),

  // ── Comfort / massage / ambient ───────────────────────────────
  _Sig(
    'massage_drv_mode',
    'Setting.SET_FRONT_LEFT_SEAT_MASSAGE_MODE',
    description: 'Driver seat massage mode',
    writeable: true,
    writeAction: 'massage.drv.mode.set',
    wireActionId: 'massage.drv.mode',
  ),
  _Sig(
    'massage_drv_level',
    'Setting.SET_FRONT_LEFT_SEAT_MASSAGE_LEVEL',
    description: 'Driver seat massage intensity level',
    writeable: true,
    writeAction: 'massage.drv.level.set',
    wireActionId: 'massage.drv.level',
  ),
  _Sig(
    'massage_co_mode',
    'Setting.SET_FRONT_RIGHT_SEAT_MASSAGE_MODE',
    description: 'Front passenger massage mode',
    writeable: true,
    writeAction: 'massage.pass.mode.set',
    wireActionId: 'massage.co.mode',
  ),
  _Sig(
    'massage_co_level',
    'Setting.SET_FRONT_RIGHT_SEAT_MASSAGE_LEVEL',
    description: 'Front passenger massage intensity',
    writeable: true,
    writeAction: 'massage.pass.level.set',
    wireActionId: 'massage.co.level',
  ),
  _Sig(
    'atmos_color',
    'Setting.SET_IAL_FRONT_COLOR',
    description: 'Ambient interior light colour (alias of atmos_front_color)',
  ),
  _Sig(
    'atmos_bright',
    'Setting.SET_IAL_FRONT_BRIGHTNESS',
    description:
        'Ambient interior light brightness (alias of atmos_front_bright)',
  ),
  _Sig(
    'atmos_front_color',
    'Setting.SET_IAL_FRONT_COLOR',
    description:
        'Front ambient light colour (read-state). Writes go through '
        'the parameterised comfort.atmos.color action.',
  ),
  _Sig(
    'atmos_front_bright',
    'Setting.SET_IAL_FRONT_BRIGHTNESS',
    description:
        'Front ambient light brightness (read-state). Writes go '
        'through comfort.atmos.bright.',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'atmos_back_color',
    'Setting.SET_IAL_BACK_COLOR',
    description:
        'Rear ambient light colour (read-state). Writes go through '
        'the parameterised comfort.atmos.color action.',
  ),
  _Sig(
    'atmos_back_bright',
    'Setting.SET_IAL_BACK_BRIGHTNESS',
    description:
        'Rear ambient light brightness (read-state). Writes go '
        'through comfort.atmos.bright.',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'wiper_f_level',
    'Wiper.WIPER_FRONT_WIPER_LEVEL',
    description: 'Front wiper level',
  ),
  _Sig(
    'wiper_f_state',
    'Wiper.WIPER_AREA_FRONT_STATE',
    description: 'Front wiper area state',
  ),
  _Sig(
    'wiper_r_state',
    'Wiper.WIPER_AREA_REAR_STATE',
    description: 'Rear wiper area state',
  ),
  _Sig(
    'wiper_relay',
    'Wiper.WIPER_RELAY_STATE',
    description: 'Wiper relay state',
  ),
  _Sig(
    'wiper_f_maint',
    'Setting.SET_FRONT_WINDSCREEN_WIPER_OVERHAUL_STATE',
    description: 'Front wiper service mode state',
  ),
  _Sig(
    'wiper_r_maint',
    'Setting.SET_REAR_WINDSCREEN_WIPER_OVERHAUL_STATE',
    description: 'Rear wiper service mode state',
  ),
  _Sig(
    'inside_light_door',
    'Setting.SET_INSIDE_LIGHT_DOOR_STATE',
    description: 'Interior light auto-on with door state',
  ),
  _Sig(
    'inside_light',
    'Setting.SET_INSIDE_LIGHT_STATE',
    description: 'Cabin interior light state',
  ),

  // ── Sensors ───────────────────────────────────────────────────
  _Sig(
    'sensor_temp',
    'Sensor.SENSOR_TEMPERATURE',
    description: 'Generic ambient temperature sensor',
    units: 'celsius',
  ),
  _Sig(
    'sensor_humidity',
    'Sensor.SENSOR_HUMIDITY',
    description: 'Cabin humidity sensor',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'sensor_light',
    'Sensor.SENSOR_LIGHT',
    description: 'Ambient light sensor state',
  ),
  _Sig(
    'sensor_slope',
    'Sensor.SENSOR_AUTO_SLOPE',
    description: 'Auto slope / road inclination',
  ),
  _Sig('pm25_in', 'Pm2p5.PM2P5_VALUE_IN', description: 'Cabin PM2.5 reading'),
  _Sig(
    'pm25_out',
    'Pm2p5.PM2P5_VALUE_OUT',
    description: 'Outside PM2.5 reading',
  ),
  _Sig(
    'pm25_online',
    'Pm2p5.PM2P5_ONLINE_STATE',
    description: 'PM2.5 sensor online state (0 offline, 1 online)',
  ),

  // ── TPMS / tyres ──────────────────────────────────────────────
  _Sig(
    'tpms_pressure_lf',
    'Instrument.INSTRUMENT_2IN1_LF_TYRE_PRESSURE',
    description: 'Tyre pressure front-left',
    units: 'kpa',
  ),
  _Sig(
    'tpms_pressure_rf',
    'Instrument.INSTRUMENT_2IN1_RF_TYRE_PRESSURE',
    description: 'Tyre pressure front-right',
    units: 'kpa',
  ),
  _Sig(
    'tpms_pressure_lr',
    'Instrument.INSTRUMENT_2IN1_LB_TYRE_PRESSURE',
    description: 'Tyre pressure rear-left',
    units: 'kpa',
  ),
  _Sig(
    'tpms_pressure_rr',
    'Instrument.INSTRUMENT_2IN1_RB_TYRE_PRESSURE',
    description: 'Tyre pressure rear-right',
    units: 'kpa',
  ),
  _Sig(
    'tpms_temp_lf',
    'Instrument.INSTRUMENT_2IN1_LF_TYRE_TEMPERATURE',
    description: 'Tyre temperature front-left',
    units: 'celsius',
  ),
  _Sig(
    'tpms_temp_rf',
    'Instrument.INSTRUMENT_2IN1_RF_TYRE_TEMPERATURE',
    description: 'Tyre temperature front-right',
    units: 'celsius',
  ),
  _Sig(
    'tpms_temp_lr',
    'Instrument.INSTRUMENT_2IN1_LB_TYRE_TEMPERATURE',
    description: 'Tyre temperature rear-left',
    units: 'celsius',
  ),
  _Sig(
    'tpms_temp_rr',
    'Instrument.INSTRUMENT_2IN1_RB_TYRE_TEMPERATURE',
    description: 'Tyre temperature rear-right',
    units: 'celsius',
  ),

  // ── Radar ─────────────────────────────────────────────────────
  _Sig(
    'radar_l',
    'Radar.RADAR_OBSTACLE_DISTANCE_LEFT',
    description: 'Left obstacle distance',
  ),
  _Sig(
    'radar_r',
    'Radar.RADAR_OBSTACLE_DISTANCE_RIGHT',
    description: 'Right obstacle distance',
  ),
  _Sig(
    'radar_lf',
    'Radar.RADAR_OBSTACLE_DISTANCE_LEFT_FRONT',
    description: 'Left-front obstacle distance',
  ),
  _Sig(
    'radar_rf',
    'Radar.RADAR_OBSTACLE_DISTANCE_RIGHT_FRONT',
    description: 'Right-front obstacle distance',
  ),
  _Sig(
    'radar_lr',
    'Radar.RADAR_OBSTACLE_DISTANCE_LEFT_REAR',
    description: 'Left-rear obstacle distance',
  ),
  _Sig(
    'radar_rr',
    'Radar.RADAR_OBSTACLE_DISTANCE_RIGHT_REAR',
    description: 'Right-rear obstacle distance',
  ),
  _Sig(
    'radar_flm',
    'Radar.RADAR_OBSTACLE_DISTANCE_FRONT_LEFT_MID',
    description: 'Front-left-mid obstacle distance',
  ),
  _Sig(
    'radar_frm',
    'Radar.RADAR_OBSTACLE_DISTANCE_FRONT_RIGHT_MID',
    description: 'Front-right-mid obstacle distance',
  ),
  _Sig(
    'radar_mr_dist',
    'Radar.RADAR_MR_OBSTACLE_DIS',
    description: 'Mid-range radar obstacle distance',
  ),
  _Sig(
    'radar_mr_state',
    'Radar.RADAR_MR_SONDE_STATUS',
    description: 'Mid-range radar sonde state',
  ),
  _Sig(
    'radar_rev_sw',
    'Radar.RADAR_REVERSE_RADAR_SWITCH_STATE',
    description: 'Reverse radar master switch state',
  ),

  // ── Statistics ────────────────────────────────────────────────
  _Sig(
    'stat_total_km',
    'Statistic.STATISTIC_TOTAL_MILEAGE',
    description: 'Lifetime odometer',
    units: 'km',
  ),
  _Sig(
    'stat_ev_km',
    'Statistic.STATISTIC_MILEAGE_EV',
    description: 'Lifetime EV-mode mileage',
    units: 'km',
  ),
  _Sig(
    'stat_hev_km',
    'Statistic.STATISTIC_MILEAGE_HEV',
    description: 'Lifetime HEV-mode mileage',
    units: 'km',
  ),
  _Sig(
    'stat_total_elec_kwh',
    'Statistic.STATISTIC_TOTAL_ELEC_CONSUMPTION',
    description: 'Lifetime electric energy used',
    units: 'kwh',
  ),
  _Sig(
    'stat_total_fuel_l',
    'Statistic.STATISTIC_TOTAL_FUEL_CONSUMPTION',
    description: 'Lifetime fuel used',
    units: 'litres',
  ),
  _Sig(
    'stat_total_elec_phm',
    'Statistic.STATISTIC_TOTAL_ELEC_CON_PHM',
    description: 'Lifetime average electric consumption per 100km',
  ),
  _Sig(
    'stat_total_fuel_phm',
    'Statistic.STATISTIC_TOTAL_FUEL_CON_PHM',
    description: 'Lifetime average fuel consumption per 100km',
  ),
  _Sig(
    'stat_last_elec_phm',
    'Statistic.STATISTIC_LAST_ELEC_CON_PHM',
    description: 'Last-trip average electric consumption per 100km',
  ),
  _Sig(
    'stat_last_fuel_phm',
    'Statistic.STATISTIC_LAST_FUEL_CON_PHM',
    description: 'Last-trip average fuel consumption per 100km',
  ),
  _Sig(
    'stat_instant_elec',
    'Statistic.STATISTIC_INSTANT_EV_CONSUME',
    description: 'Instant electric consumption',
  ),
  _Sig(
    'stat_instant_fuel',
    'Statistic.STATISTIC_INSTANT_FUEL_CONSUME',
    description: 'Instant fuel consumption',
  ),
  _Sig(
    'stat_battery_health',
    'Statistic.STATISTIC_BATTERY_HEALTHY_INDEX',
    description: 'Battery health index',
  ),
  _Sig(
    'stat_battery_avg_temp',
    'Statistic.STATISTIC_AVERAGE_BATTERY_TEMP',
    description: 'Average pack cell temperature',
    units: 'celsius',
  ),
  _Sig(
    'stat_battery_max_temp',
    'Statistic.STATISTIC_HIGHEST_BATTERY_TEMP',
    description: 'Highest pack cell temperature',
    units: 'celsius',
  ),
  _Sig(
    'stat_battery_min_temp',
    'Statistic.STATISTIC_LOWEST_BATTERY_TEMP',
    description: 'Lowest pack cell temperature',
    units: 'celsius',
  ),
  _Sig(
    'stat_battery_max_v',
    'Statistic.STATISTIC_HIGHEST_BATTERY_VOLTAGE',
    description: 'Highest pack cell voltage',
    units: 'volts',
  ),
  _Sig(
    'stat_battery_min_v',
    'Statistic.STATISTIC_LOWEST_BATTERY_VOLTAGE',
    description: 'Lowest pack cell voltage',
    units: 'volts',
  ),

  // ============================================================
  // EXPANSION ENTRIES
  // ============================================================

  // ── Doors / closures (expansion) ──────────────────────────────
  _Sig(
    'door_lf_current_state',
    'Bodywork.BODYWORK_LEFT_FRONT_WINDOW_CURRENT_STATE',
    description: 'Front-left window detailed state (moving / idle / fault)',
    category: 'doors',
  ),
  _Sig(
    'door_rf_current_state',
    'Bodywork.BODYWORK_RIGHT_FRONT_WINDOW_CURRENT_STATE',
    description: 'Front-right window detailed state',
    category: 'doors',
  ),
  _Sig(
    'door_lr_current_state',
    'Bodywork.BODYWORK_LEFT_REAR_WINDOW_CURRENT_STATE',
    description: 'Rear-left window detailed state',
    category: 'doors',
  ),
  _Sig(
    'door_rr_current_state',
    'Bodywork.BODYWORK_RIGHT_REAR_WINDOW_CURRENT_STATE',
    description: 'Rear-right window detailed state',
    category: 'doors',
  ),
  _Sig(
    'door_lf_status_flag',
    'Bodywork.BODYWORK_LF_DOOR_STATUS_FLAG',
    description: 'Front-left door status flag (latch / ajar / closed)',
    category: 'doors',
  ),
  _Sig(
    'door_rf_status_flag',
    'Bodywork.BODYWORK_RF_DOOR_STATUS_FLAG',
    description: 'Front-right door status flag',
    category: 'doors',
  ),
  _Sig(
    'door_lr_status_flag',
    'Bodywork.BODYWORK_LR_DOOR_STATUS_FLAG',
    description: 'Rear-left door status flag',
    category: 'doors',
  ),
  _Sig(
    'door_rr_status_flag',
    'Bodywork.BODYWORK_RR_DOOR_STATUS_FLAG',
    description: 'Rear-right door status flag',
    category: 'doors',
  ),
  _Sig(
    'door_front_flag',
    'Bodywork.BODYWORK_FRONT_DOOR_STATUS_FLAG',
    description: 'Combined front door status flag',
    category: 'doors',
  ),
  _Sig(
    'door_back_flag',
    'Bodywork.BODYWORK_BACK_DOOR_STATUS_FLAG',
    description: 'Back / tailgate door status flag',
    category: 'doors',
  ),
  _Sig(
    'door_lr_lock_status',
    'Bodywork.BODYWORK_LR_DOOR_LOCK_STATUS',
    description: 'Rear-left door lock latch status',
    category: 'doors',
  ),
  _Sig(
    'door_rr_lock_status',
    'Bodywork.BODYWORK_RR_DOOR_LOCK_STATUS',
    description: 'Rear-right door lock latch status',
    category: 'doors',
  ),
  _Sig(
    'door_rf_lock_status',
    'Bodywork.BODYWORK_RF_DOOR_LOCK_STATUS',
    description: 'Front-right door lock latch status',
    category: 'doors',
  ),
  _Sig(
    'door_lf_handle_ext',
    'Bodywork.BODYWORK_LEFT_FRONT_DOOR_HANDLE_EXTERNAL_SWITCH_SIGNAL',
    description: 'Front-left exterior door-handle switch (0 idle, 1 pulled)',
    category: 'doors',
  ),
  _Sig(
    'door_lf_handle_int',
    'Bodywork.BODYWORK_LEFT_FRONT_DOOR_HANDLE_INTERNAL_SWITCH_SIGNAL',
    description: 'Front-left interior door-handle switch',
    category: 'doors',
  ),
  _Sig(
    'door_rf_handle_ext',
    'Bodywork.BODYWORK_RIGHT_FRONT_DOOR_HANDLE_EXTERNAL_SWITCH_SIGNAL',
    description: 'Front-right exterior door-handle switch',
    category: 'doors',
  ),
  _Sig(
    'door_rf_handle_int',
    'Bodywork.BODYWORK_RIGHT_FRONT_DOOR_HANDLE_INTERNAL_SWITCH_SIGNAL',
    description: 'Front-right interior door-handle switch',
    category: 'doors',
  ),
  _Sig(
    'door_lr_handle_ext',
    'Bodywork.BODYWORK_LEFT_REAR_DOOR_HANDLE_EXTERNAL_SWITCH_SIGNAL',
    description: 'Rear-left exterior door-handle switch',
    category: 'doors',
  ),
  _Sig(
    'door_lr_handle_int',
    'Bodywork.BODYWORK_LEFT_REAR_DOOR_HANDLE_INTERNAL_SWITCH_SIGNAL',
    description: 'Rear-left interior door-handle switch',
    category: 'doors',
  ),
  _Sig(
    'door_lf_electric_pos',
    'Bodywork.BODYWORK_LF_ELECTRIC_DOOR_CURRENT_POSITION',
    description: 'Front-left electric-door current position',
    category: 'doors',
  ),
  _Sig(
    'door_rf_electric_pos',
    'Bodywork.BODYWORK_RF_ELECTRIC_DOOR_CURRENT_POSITION',
    description: 'Front-right electric-door current position',
    category: 'doors',
  ),
  _Sig(
    'door_lr_electric_pos',
    'Bodywork.BODYWORK_LR_ELECTRIC_DOOR_CURRENT_POSITION',
    description: 'Rear-left electric-door current position',
    category: 'doors',
  ),
  _Sig(
    'door_rr_electric_pos',
    'Bodywork.BODYWORK_RR_ELECTRIC_DOOR_CURRENT_POSITION',
    description: 'Rear-right electric-door current position',
    category: 'doors',
  ),
  _Sig(
    'door_lf_electric_obstacle',
    'Bodywork.BODYWORK_LF_ELECTRIC_DOOR_OBSTACLE',
    description: 'Front-left electric-door obstacle detected',
    category: 'doors',
  ),
  _Sig(
    'door_rf_electric_obstacle',
    'Bodywork.BODYWORK_RF_ELECTRIC_DOOR_OBSTACLE',
    description: 'Front-right electric-door obstacle detected',
    category: 'doors',
  ),
  _Sig(
    'door_lr_electric_obstacle',
    'Bodywork.BODYWORK_LR_ELECTRIC_DOOR_OBSTACLE',
    description: 'Rear-left electric-door obstacle detected',
    category: 'doors',
  ),
  _Sig(
    'door_rr_electric_obstacle',
    'Bodywork.BODYWORK_RR_ELECTRIC_DOOR_OBSTACLE',
    description: 'Rear-right electric-door obstacle detected',
    category: 'doors',
  ),
  _Sig(
    'door_back_position',
    'Bodywork.BODYWORK_BACKDOOR_CURRENT_POSITION',
    description: 'Powered tailgate current position',
    category: 'doors',
  ),
  _Sig(
    'door_back_open_confirm',
    'Bodywork.BODYWORK_BACK_DOOR_OPEN_STATUS_CONFIRM',
    description: 'Powered tailgate fully-open confirm (0 not open, 1 open)',
    category: 'doors',
  ),
  _Sig(
    'door_back_maint',
    'Bodywork.BODYWORK_BACK_DOOR_MAINTENANCE_STATUS',
    description: 'Powered tailgate maintenance / service mode',
    category: 'doors',
  ),
  _Sig(
    'fridge_door',
    'Bodywork.BODYWORK_FRIDGE_DOOR_SEATE',
    description: 'Cabin fridge door state (0 closed, 1 open)',
    category: 'doors',
  ),
  _Sig(
    'door_double_click_unlock',
    'Bodywork.BODYWORK_DOUBLE_CILCK_UNLOCK_DOOR',
    description: 'Key fob double-click unlock event',
    category: 'doors',
  ),
  _Sig(
    'door_knock_unlock',
    'Bodywork.BODYWORK_KNOCK_UNLOCK_DOOR',
    description: 'Knock-to-unlock event',
    category: 'doors',
  ),
  _Sig(
    'door_kick_sense',
    'Bodywork.BODYWORK_KICK_DOOR_SENSE_CONFIG',
    description: 'Kick-sense door config / status',
    category: 'doors',
  ),
  _Sig(
    'door_bt_unlock',
    'Bodywork.BODYWORK_BT_UNLOCK',
    description: 'Bluetooth key unlock event',
    category: 'doors',
  ),
  _Sig(
    'door_bt_key',
    'Bodywork.BODYWORK_BT_KEY_CODE',
    description: 'Bluetooth key code',
    category: 'doors',
  ),
  _Sig(
    'door_nfc_key',
    'Bodywork.BODYWORK_CARD_NFC_KEY_STATE',
    description: 'NFC card key state',
    category: 'doors',
  ),
  _Sig(
    'door_highspeed_auto_close',
    'Bodywork.BODYWORK_HIGHSPEED_AUTOMATIC_WINDOW_CLOSING',
    description: 'High-speed auto window-close enable',
    category: 'doors',
  ),
  _Sig(
    'rain_auto_close_legacy',
    'Bodywork.BODYWORK_CLOSE_WINDOW_FOR_RAIN',
    description: 'Auto-close windows on rain (legacy variant)',
    category: 'doors',
  ),
  _Sig(
    'rear_window_lock_state',
    'Door.DOOR_LOCK_REAR_WINDOW_LOCK_STATE',
    description: 'Rear-window child-lock state',
    category: 'doors',
  ),
  _Sig(
    'door_lock_heat_protect',
    'Door.DOOR_LOCK_HEAT_PROTECT_STATE',
    description: 'Door-lock heat protection state',
    category: 'doors',
  ),
  _Sig(
    'door_lock_cockpit_hatch',
    'Door.DOOR_LOCK_COCKPIT_HATCH_DOOR_SWITCH_STATE',
    description: 'Cockpit hatch lock switch state',
    category: 'doors',
  ),
  _Sig(
    'window_lf_thermal',
    'Bodywork.BODYWORK_LEFT_FRONT_WINDOW_THERMAL_PROTECTION',
    description: 'Front-left window thermal protection active',
    category: 'doors',
  ),
  _Sig(
    'window_rf_thermal',
    'Bodywork.BODYWORK_RIGHT_FRONT_WINDOW_THERMAL_PROTECTION',
    description: 'Front-right window thermal protection',
    category: 'doors',
  ),
  _Sig(
    'window_lr_thermal',
    'Bodywork.BODYWORK_LEFT_REAR_WINDOW_THERMAL_PROTECTION',
    description: 'Rear-left window thermal protection',
    category: 'doors',
  ),
  _Sig(
    'window_rr_thermal',
    'Bodywork.BODYWORK_RIGHT_REAR_WINDOW_THERMAL_PROTECTION',
    description: 'Rear-right window thermal protection',
    category: 'doors',
  ),
  _Sig(
    'window_lf_permit',
    'Bodywork.BODYWORK_LEFT_FRONT_WINDOW_PERMIT',
    description: 'Front-left window movement permit flag',
    category: 'doors',
  ),
  _Sig(
    'sunshade_front_thermal',
    'Bodywork.BODYWORK_FRONT_SUNSHADE_THERMAL_PROTECTION',
    description: 'Front sunshade thermal protection',
    category: 'doors',
  ),
  _Sig(
    'sunroof_blind_closed',
    'Bodywork.BODYWORK_REAR_SUNROOF_WINDOWBLIND_CLOSED_STATUS',
    description: 'Rear sunroof blind closed status',
    category: 'doors',
  ),

  // ── Mirrors ───────────────────────────────────────────────────
  _Sig(
    'mirror_l_pos_h',
    'Bodywork.BODY_LEFT_REARVIEW_MIRROR_HORIZONTAL_POSITION',
    description: 'Left mirror horizontal position',
    category: 'doors',
  ),
  _Sig(
    'mirror_l_pos_v',
    'Bodywork.BODY_LEFT_REARVIEW_MIRROR_VERTICAL_POSITION',
    description: 'Left mirror vertical position',
    category: 'doors',
  ),
  _Sig(
    'mirror_r_pos_h',
    'Bodywork.BODY_RIGHT_REARVIEW_MIRROR_HORIZONTAL_POSITION',
    description: 'Right mirror horizontal position',
    category: 'doors',
  ),
  _Sig(
    'mirror_r_pos_v',
    'Bodywork.BODY_RIGHT_REARVIEW_MIRROR_VERTICAL_POSITION',
    description: 'Right mirror vertical position',
    category: 'doors',
  ),
  _Sig(
    'mirror_l_working',
    'Setting.SETTING_LEFT_OUT_MIRROR_SYSTEM_WORKING_STATUS',
    description: 'Left exterior mirror motor working state',
    category: 'doors',
  ),
  _Sig(
    'mirror_r_working',
    'Setting.SETTING_RIGHT_OUT_MIRROR_SYSTEM_WORKING_STATUS',
    description: 'Right exterior mirror motor working state',
    category: 'doors',
  ),
  _Sig(
    'mirror_auto_fold',
    'Setting.SET_CAR_EXT_REARVIEW_MIRROR_AUTO_FOLD',
    description: 'Exterior mirror auto-fold-on-lock state',
    category: 'doors',
    writeable: true,
    writeAction: 'mirror.fold.toggle',
  ),
  _Sig(
    'mirror_has_auto_fold',
    'Setting.SET_HAVE_REARVIEW_MIRROR_AUTO_FOLD',
    description: 'Vehicle supports mirror auto-fold (0 no, 1 yes)',
    category: 'doors',
  ),
  _Sig(
    'mirror_inside_screen',
    'Setting.SET_CAR_INSIDE_REAR_MIRROR_SCREEN_SWITCH',
    description: 'Interior rear-view mirror digital screen on/off',
    category: 'doors',
  ),
  _Sig(
    'mirror_l_pos_update',
    'Setting.SET_LEFT_OUT_MIRROR_POS_UPDATE_STATE',
    description: 'Left mirror position update / memory state',
    category: 'doors',
  ),
  _Sig(
    'mirror_r_pos_update',
    'Setting.SET_RIGHT_OUT_MIRROR_POS_UPDATE_STATE',
    description: 'Right mirror position update / memory state',
    category: 'doors',
  ),

  // ── Climate (expansion) ───────────────────────────────────────
  _Sig(
    'ac_work_mode',
    'Ac.AC_AIR_CONDITION_WORK_MODE',
    description: 'Active AC work mode (cool / heat / auto)',
  ),
  _Sig(
    'ac_lf_work_mode',
    'Ac.AC_LF_AC_WORK_MODE',
    description: 'Driver-zone AC work mode',
  ),
  _Sig(
    'ac_rf_work_mode',
    'Ac.AC_RF_AC_WORK_MODE',
    description: 'Front-passenger zone AC work mode',
  ),
  _Sig(
    'ac_rear_work_mode',
    'Ac.AC_REAR_WORK_MODE',
    description: 'Rear AC work mode',
  ),
  _Sig(
    'ac_rear_wind_level',
    'Ac.AC_REAR_WIND_LEVEL',
    description: 'Rear AC fan level',
  ),
  _Sig(
    'ac_rear_wind_mode',
    'Ac.AC_REAR_WIND_MODE',
    description: 'Rear AC wind distribution mode',
  ),
  _Sig(
    'ac_rear_max_wind',
    'Ac.AC_REAR_MAX_WIND_LEVEL',
    description: 'Rear AC max wind level',
  ),
  _Sig(
    'ac_rear_ctrl_mode',
    'Ac.AC_REAR_CTRL_MODE',
    description: 'Rear AC control mode (manual / auto)',
  ),
  _Sig(
    'ac_rear_panel_lock',
    'Ac.AC_REAR_PANEL_LOCK',
    description: 'Rear AC panel lock state',
  ),
  _Sig(
    'ac_rear_key_lock',
    'Ac.AC_REAR_KEY_LOCK_FUNCTION',
    description: 'Rear AC key lock function',
  ),
  _Sig(
    'ac_rear_lock_state',
    'Ac.AC_REAR_LOCK_STATE',
    description: 'Rear AC panel lock state flag',
  ),
  _Sig(
    'ac_middle_power',
    'Ac.AC_MIDDLE_POWER',
    description: 'Middle-row AC power state',
  ),
  _Sig(
    'ac_middle_l_auto',
    'Ac.AC_MIDDLE_LEFT_AUTOMATIC_BUTTON',
    description: 'Middle-left zone AC auto button state',
  ),
  _Sig(
    'ac_middle_l_switch',
    'Ac.AC_MIDDLE_LEFT_SWITCH_BUTTON',
    description: 'Middle-left zone AC switch state',
  ),
  _Sig(
    'ac_middle_l_temp',
    'Ac.AC_MIDDLE_LEFT_TEMP',
    description: 'Middle-left zone target temperature',
    units: 'celsius',
  ),
  _Sig(
    'ac_middle_l_wind',
    'Ac.AC_MIDDLE_LEFT_WIND_LEVEL',
    description: 'Middle-left zone fan level',
  ),
  _Sig(
    'ac_middle_l_wind_mode',
    'Ac.AC_MIDDLE_LEFT_WIND_MODE',
    description: 'Middle-left zone wind mode',
  ),
  _Sig(
    'ac_middle_l_work_mode',
    'Ac.AC_MIDDLE_LEFT_WORK_MODE',
    description: 'Middle-left zone work mode',
  ),
  _Sig(
    'ac_middle_r_auto',
    'Ac.AC_MIDDLE_RIGHT_AUTOMATIC_BUTTON',
    description: 'Middle-right zone AC auto button state',
  ),
  _Sig(
    'ac_middle_r_temp',
    'Ac.AC_MIDDLE_RIGHT_TEMP',
    description: 'Middle-right zone target temperature',
    units: 'celsius',
  ),
  _Sig(
    'ac_middle_r_wind',
    'Ac.AC_MIDDLE_RIGHT_WIND_LEVEL',
    description: 'Middle-right zone fan level',
  ),
  _Sig(
    'ac_middle_r_wind_mode',
    'Ac.AC_MIDDLE_RIGHT_WIND_MODE',
    description: 'Middle-right zone wind mode',
  ),
  _Sig(
    'ac_middle_r_work_mode',
    'Ac.AC_MIDDLE_RIGHT_WORK_MODE',
    description: 'Middle-right zone work mode',
  ),
  _Sig(
    'ac_extreme_cool',
    'Ac.AC_EXTREME_COOL_STATUS',
    description: 'Extreme-cool mode active (0 off, 1 on)',
  ),
  _Sig(
    'ac_extreme_heat',
    'Ac.AC_EXTREME_HEAT_STATUS',
    description: 'Extreme-heat mode active (0 off, 1 on)',
  ),
  _Sig('ac_warm_state', 'Ac.AC_WARM_STATE', description: 'AC warm-up state'),
  _Sig('ac_ptc_state', 'Ac.AC_PTC_STATE', description: 'PTC heater state'),
  _Sig(
    'ac_ptc_preheat',
    'Ac.AC_PTC_PREHEAT_SIGNAL',
    description: 'PTC pre-heat signal',
  ),
  _Sig(
    'ac_intelligent_power',
    'Ac.AC_INTELLIGENT_AC_POWER',
    description: 'Intelligent AC power state',
  ),
  _Sig(
    'ac_smart_partition',
    'Ac.AC_SMART_PARTITION_CONFIGURATION_STATUS',
    description: 'Smart-partition zone configuration state',
  ),
  _Sig(
    'ac_temp_inside_filtered',
    'Ac.AC_TEMP_INSIDE_FILTERING',
    description: 'Filtered cabin temperature reading',
    units: 'celsius',
  ),
  _Sig(
    'ac_main_seat_heat_mode',
    'Ac.AC_MAIN_DRIVE_SEAT_HEATING_CONTROL_MODE',
    description: 'Driver seat heating control mode',
  ),
  _Sig(
    'ac_pass_seat_heat_mode',
    'Ac.AC_PASSENGER_SEAT_HEATING_CONTROL_MODE',
    description: 'Passenger seat heating control mode',
  ),
  _Sig(
    'ac_rl_seat_heat_mode',
    'Ac.AC_REAR_LEFT_SEAT_HEATING_CONTROL_MODE',
    description: 'Rear-left seat heating control mode',
  ),
  _Sig(
    'ac_rr_seat_heat_mode',
    'Ac.AC_REAR_RIGHT_SEAT_HEATING_CONTROL_MODE',
    description: 'Rear-right seat heating control mode',
  ),
  _Sig(
    'ac_main_seat_heat_status',
    'Ac.AC_MAIN_DRIVE_SEAT_HEATING_STATUS',
    description: 'Driver seat heating on/off',
  ),
  _Sig(
    'ac_pass_seat_heat_status',
    'Ac.AC_PASSENGER_SEAT_HEATING_STATUS',
    description: 'Passenger seat heating on/off',
  ),
  _Sig(
    'ac_rl_seat_heat_status',
    'Ac.AC_REAR_LEFT_SEAT_HEATING_STATUS',
    description: 'Rear-left seat heating on/off',
  ),
  _Sig(
    'ac_rr_seat_heat_status',
    'Ac.AC_REAR_RIGHT_SEAT_HEATING_STATUS',
    description: 'Rear-right seat heating on/off',
  ),
  _Sig(
    'ac_main_seat_vent_status',
    'Ac.AC_MAIN_DRIVE_SEAT_VENTILATING_STATUS',
    description: 'Driver seat ventilation on/off',
  ),
  _Sig(
    'ac_pass_seat_vent_status',
    'Ac.AC_PASSENGER_SEAT_VENTILATING_STATUS',
    description: 'Passenger seat ventilation on/off',
  ),
  _Sig(
    'ac_rl_seat_vent_status',
    'Ac.AC_REAR_LEFT_SEAT_VENTILATING_STATUS',
    description: 'Rear-left seat ventilation on/off',
  ),
  _Sig(
    'ac_rr_seat_vent_status',
    'Ac.AC_REAR_RIGHT_SEAT_VENTILATING_STATUS',
    description: 'Rear-right seat ventilation on/off',
  ),
  _Sig(
    'ac_main_seat_vent_mode',
    'Ac.AC_MAIN_DRIVE_SEAT_VENTILATING_CONTROL_MODE',
    description: 'Driver seat ventilation control mode',
  ),
  _Sig(
    'ac_pass_seat_vent_mode',
    'Ac.AC_PASSENGER_SEAT_VENTILATING_CONTROL_MODE',
    description: 'Passenger seat ventilation control mode',
  ),
  _Sig(
    'ac_rl_seat_vent_mode',
    'Ac.AC_REAR_LEFT_SEAT_VENTILATING_CONTROL_MODE',
    description: 'Rear-left seat ventilation control mode',
  ),
  _Sig(
    'ac_rr_seat_vent_mode',
    'Ac.AC_REAR_RIGHT_SEAT_VENTILATING_CONTROL_MODE',
    description: 'Rear-right seat ventilation control mode',
  ),
  _Sig(
    'ac_lf_seat_heat_cfg',
    'Ac.AC_LF_SEAT_HEATING_CONFIG',
    description: 'Driver seat heating hardware configured',
  ),
  _Sig(
    'ac_rf_seat_heat_cfg',
    'Ac.AC_RF_SEAT_HEATING_CONFIG',
    description: 'Passenger seat heating hardware configured',
  ),
  _Sig(
    'ac_lr_seat_heat_cfg',
    'Ac.AC_LR_SEAT_HEATING_CONFIG',
    description: 'Rear-left seat heating hardware configured',
  ),
  _Sig(
    'ac_rr_seat_heat_cfg',
    'Ac.AC_RR_SEAT_HEATING_CONFIG',
    description: 'Rear-right seat heating hardware configured',
  ),
  _Sig(
    'ac_lf_seat_vent_cfg',
    'Ac.AC_LF_SEAT_VENTILATION_CONFIG',
    description: 'Driver seat ventilation hardware configured',
  ),
  _Sig(
    'ac_rf_seat_vent_cfg',
    'Ac.AC_RF_SEAT_VENTILATION_CONFIG',
    description: 'Passenger seat ventilation hardware configured',
  ),
  _Sig(
    'ac_lr_seat_vent_cfg',
    'Ac.AC_LR_SEAT_VENTILATION_CONFIG',
    description: 'Rear-left seat ventilation hardware configured',
  ),
  _Sig(
    'ac_rr_seat_vent_cfg',
    'Ac.AC_RR_SEAT_VENTILATION_CONFIG',
    description: 'Rear-right seat ventilation hardware configured',
  ),
  _Sig(
    'ac_passenger_auto',
    'Ac.AC_PASSENGER_AUTOMATIC_AIR_CONDITION',
    description: 'Passenger zone AC auto mode',
  ),
  _Sig(
    'ac_passenger_wind',
    'Ac.AC_PASSENGER_WINDLEVEL',
    description: 'Passenger zone wind level',
  ),
  _Sig(
    'ac_drv_left_tuyere',
    'Ac.AC_MAIN_DRIVE_LEFT_TUYERE_SWITCH_STATUS',
    description: 'Driver left vent open / closed',
  ),
  _Sig(
    'ac_drv_right_tuyere',
    'Ac.AC_MAIN_DRIVE_RIGHT_TUYERE_SWITCH_STATUS',
    description: 'Driver right vent open / closed',
  ),
  _Sig(
    'ac_pass_left_tuyere',
    'Ac.AC_PASSENGER_LEFT_TUYERE_SWITCH_STATUS',
    description: 'Passenger left vent open / closed',
  ),
  _Sig(
    'ac_pass_right_tuyere',
    'Ac.AC_PASSENGER_RIGHT_TUYERE_SWITCH_STATUS',
    description: 'Passenger right vent open / closed',
  ),
  _Sig(
    'ac_drv_left_tuyere_lr',
    'Ac.AC_MAIN_DRIVE_LEFT_TUYERE_LEFT_AND_RIGHT_ADJUSTMENT_SIGNAL',
    description: 'Driver left vent left/right position',
  ),
  _Sig(
    'ac_drv_left_tuyere_ud',
    'Ac.AC_MAIN_DRIVE_LEFT_TUYERE_UP_AND_DOWN_ADJUSTMENT_SIGNAL',
    description: 'Driver left vent up/down position',
  ),
  _Sig(
    'ac_drv_right_tuyere_lr',
    'Ac.AC_MAIN_DRIVE_RIGHT_TUYERE_LEFT_AND_RIGHT_ADJUSTMENT_SIGNAL',
    description: 'Driver right vent left/right position',
  ),
  _Sig(
    'ac_drv_right_tuyere_ud',
    'Ac.AC_MAIN_DRIVE_RIGHT_TUYERE_UP_AND_DOWN_ADJUSTMENT_SIGNAL',
    description: 'Driver right vent up/down position',
  ),
  _Sig(
    'ac_drv_sweep_lr',
    'Ac.AC_MAIN_DRIVE_LEFT_AND_RIGHT_SWEEP_SIGNAL',
    description: 'Driver vents sweep left/right active',
  ),
  _Sig(
    'ac_drv_sweep_ud',
    'Ac.AC_MAIN_DRIVE_UP_AND_DOWN_SWEEP_SIGNAL',
    description: 'Driver vents sweep up/down active',
  ),
  _Sig(
    'ac_pass_sweep_lr',
    'Ac.AC_PASSENGER_LEFT_AND_RIGHT_SWEEP_SIGNAL',
    description: 'Passenger vents sweep left/right active',
  ),
  _Sig(
    'ac_pass_sweep_ud',
    'Ac.AC_PASSENGER_UP_AND_DOWN_SWEEP_SIGNAL',
    description: 'Passenger vents sweep up/down active',
  ),
  _Sig(
    'ac_center_tuyere',
    'Ac.AC_CENTER_TUYERE_SIGNAL',
    description: 'Centre vent open/closed signal',
  ),
  _Sig(
    'ac_center_tuyere_close',
    'Ac.AC_CENTER_TUYERE_CLOSE_SIGNAL',
    description: 'Centre vent close signal',
  ),
  _Sig(
    'ac_center_tuyere_lr',
    'Ac.AC_CENTER_TUYERE_LEFT_RIGHT_ADJUSTMENT_SIGNAL',
    description: 'Centre vent left/right adjustment',
  ),
  _Sig(
    'ac_center_tuyere_ud',
    'Ac.AC_CENTER_TUYERE_UP_DOWN_ADJUSTMENT_SIGNAL',
    description: 'Centre vent up/down adjustment',
  ),
  _Sig(
    'ac_drv_free_wind',
    'Ac.AC_MAIN_DRIVE_FREE_WIND_BUTTON_STATUS',
    description: 'Driver "free wind" (no direct blow) state',
  ),
  _Sig(
    'ac_pass_free_wind',
    'Ac.AC_PASSENGER_FREE_WIND_BUTTON_STATUS',
    description: 'Passenger "free wind" state',
  ),
  _Sig(
    'ac_drv_blow_mode',
    'Ac.AC_MAIN_DRIVE_BLOWS_MODE_SIGNAL_TO_PEOPLE',
    description: 'Driver-side blow-to-person mode',
  ),
  _Sig(
    'ac_pass_blow_mode',
    'Ac.AC_PASSENGER_BLOWS_MODE_SIGNAL_TO_PEOPLE',
    description: 'Passenger-side blow-to-person mode',
  ),
  _Sig(
    'ac_drv_avoid_blow',
    'Ac.AC_MAIN_DRIVE_SIDE_TO_AVOID_BLOWING_MODE_SIGNAL_TO_PEOPLE',
    description: 'Driver-side avoid-blow mode',
  ),
  _Sig(
    'ac_pass_avoid_blow',
    'Ac.AC_PASSENGER_SIDE_TO_AVOID_BLOWING_MODE_SIGNAL_TO_PEOPLE',
    description: 'Passenger-side avoid-blow mode',
  ),
  _Sig(
    'ac_dms_mode',
    'Ac.AC_DMS_MODE_FEEDBAEK',
    description: 'Driver-monitoring AC mode feedback',
  ),
  _Sig(
    'ac_cockpit_purify',
    'Ac.AC_COCKPIT_PURIFICATION_STATUS',
    description: 'Cabin air purification state',
  ),
  _Sig(
    'ac_high_temp_antivirus',
    'Ac.AC_HIGH_TEMP_ANTIVIRUS_STATE',
    description: 'High-temperature anti-virus sterilisation state',
  ),
  _Sig(
    'ac_high_temp_antivirus_cd',
    'Ac.AC_HIGH_TEMP_ANTIVIRUS_COUNT_DOWN',
    description: 'High-temp anti-virus countdown',
    units: 'seconds',
  ),
  _Sig(
    'ac_high_temp_taste_remove',
    'Ac.AC_HIGH_TEMP_REMOVE_TASTE_STATUS',
    description: 'High-temp odour-remove state',
  ),
  _Sig(
    'ac_atom_defog',
    'Ac.AC_ATOM_DEFOGGING_STATUS',
    description: 'Atomised defogging state',
  ),
  _Sig(
    'ac_air_quality_in',
    'Ac.AC_AIR_QUAL_CTRL_MENU_STATE',
    description: 'Air-quality control menu state',
  ),
  _Sig(
    'ac_co2_out',
    'Ac.AC_CO2_CONCENTRATION_OUTSIDE_THE_CAR',
    description: 'Outside CO2 concentration',
  ),
  _Sig(
    'ac_co2_level_out',
    'Ac.AC_CO2_LEVEL_OUTSIDE_THE_CAR',
    description: 'Outside CO2 level enum',
  ),
  _Sig(
    'ac_aqs_level_out',
    'Ac.AC_AQS_LEVEL_OUTSIDE_THE_CAR',
    description: 'Outside air-quality sensor level',
  ),
  _Sig(
    'ac_air_quality_out',
    'Ac.AC_AIR_QUALITY_COMPREHENSIVE_LEVEL_OUTSIDE_THE_CAR',
    description: 'Comprehensive outside air-quality level',
  ),
  _Sig(
    'ac_aqs_cfg',
    'Ac.AC_AQS_CONFIG_FLAG',
    description: 'AQS sensor configured flag',
  ),
  _Sig(
    'ac_appointment_open',
    'Ac.AC_APPOINTMENT_OPEN_AC_STATUS',
    description: 'Scheduled AC pre-heat / pre-cool active',
  ),
  _Sig(
    'ac_online',
    'Ac.AC_ONLINE_STATE',
    description: 'AC module online state',
  ),
  _Sig('ac_type', 'Ac.AC_TYPE', description: 'AC system type code'),
  _Sig(
    'ac_has_auto',
    'Ac.AC_HAS_AC_AUTO_MODE',
    description: 'Vehicle supports AC auto mode',
  ),
  _Sig(
    'ac_has_defrost',
    'Ac.AC_HAS_AC_DEFROST',
    description: 'Vehicle supports auto-defrost',
  ),
  _Sig(
    'ac_has_remote',
    'Ac.AC_HAS_AC_REMOTE_CTRL',
    description: 'Vehicle supports remote AC control',
  ),
  _Sig(
    'ac_has_perfume',
    'Ac.AC_HAS_PERFUME_CONFIGURATION',
    description: 'Vehicle supports cabin perfume',
  ),
  _Sig(
    'ac_fourzone_cfg',
    'Ac.AC_FOURZONE_AIR_CONDITION_CONFIG',
    description: 'Four-zone AC configured',
  ),
  _Sig(
    'perfume_current_type',
    'Ac.AC_CURRENT_PERFUME_TYPE',
    description: 'Currently selected perfume type',
  ),
  _Sig(
    'perfume_first_name',
    'Ac.AC_THE_FIRST_PERFUME_NAME',
    description: 'First perfume bottle name',
  ),
  _Sig(
    'perfume_first_surplus',
    'Ac.AC_THE_FIRST_PERFUME_SURPLUS',
    description: 'First perfume bottle remaining',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'perfume_second_name',
    'Ac.AC_THE_SECOND_PERFUME_NAME',
    description: 'Second perfume bottle name',
  ),
  _Sig(
    'perfume_second_surplus',
    'Ac.AC_THE_SECOND_PERFUME_SURPLUS',
    description: 'Second perfume bottle remaining',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'perfume_third_name',
    'Ac.AC_THE_THIRD_PERFUME_NAME',
    description: 'Third perfume bottle name',
  ),
  _Sig(
    'perfume_third_surplus',
    'Ac.AC_THE_THIRD_PERFUME_SURPLUS',
    description: 'Third perfume bottle remaining',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'perfume_concentration',
    'Ac.AC_PERFUME_CONCENTRATION_FEEDBACK',
    description: 'Perfume concentration feedback',
  ),
  _Sig(
    'fragrance_timing_duration',
    'Ac.AC_FRAGRANCE_TIMING_DURATION_FEEDBACK',
    description: 'Fragrance timer duration feedback',
    units: 'minutes',
  ),

  // ── Lights (expansion) ────────────────────────────────────────
  _Sig(
    'light_low_beam_blink',
    'Light.LIGHT_LOW_BEAM_BLINK_STATE',
    description: 'Low-beam blink (flash-to-pass) state',
    category: 'lights',
    threeD: true,
  ),
  _Sig(
    'light_low_beam_state',
    'Light.LIGHT_LOW_BEAM_LIGHTS_STATE',
    description: 'Low-beam combined state',
    category: 'lights',
  ),
  _Sig(
    'light_high_beam_left',
    'Light.LIGHT_LEFT_HIGH_BEAM_STATUS',
    description: 'Left high-beam status',
    category: 'lights',
  ),
  _Sig(
    'light_high_beam_right',
    'Light.LIGHT_RIGHT_HIGH_BEAM_STATUS',
    description: 'Right high-beam status',
    category: 'lights',
  ),
  _Sig(
    'light_low_beam_left',
    'Light.LIGHT_LEFT_LOW_BEAM_STATUS',
    description: 'Left low-beam status',
    category: 'lights',
  ),
  _Sig(
    'light_low_beam_adb',
    'Light.LIGHT_LOW_BEAM_LIGHT_ADB',
    description: 'Low-beam ADB (adaptive driving beam) state',
    category: 'lights',
  ),
  _Sig(
    'light_high_beam_adb',
    'Light.LIGHT_HIGH_BEAM_LIGHT_ADB',
    description: 'High-beam ADB state',
    category: 'lights',
  ),
  _Sig(
    'light_high_beam_indicator',
    'Light.LIGHT_HIGH_BEAM_INDICATOR',
    description: 'Cluster high-beam indicator lamp',
    category: 'lights',
  ),
  _Sig(
    'light_high_low_enhance',
    'Light.LIGHT_HIGH_LOW_BEAM_ENHANCE_STATE',
    description: 'High/low beam auto-enhance state',
    category: 'lights',
  ),
  _Sig(
    'light_afs_status',
    'Light.LIGHT_AFS_STATUS',
    description: 'Adaptive front-lighting system status',
    category: 'lights',
  ),
  _Sig(
    'light_afs_switch',
    'Light.LIGHT_AFS_SWITCH',
    description: 'AFS user switch',
    category: 'lights',
  ),
  _Sig(
    'light_als_status',
    'Light.LIGHT_ALS_FUNCTION_STATUS',
    description: 'Auto light sensor (ALS) function status',
    category: 'lights',
  ),
  _Sig(
    'light_auto_mode',
    'Light.LIGHT_AUTOMATIC_LIGHT_MODE',
    description: 'Headlight auto mode state',
    category: 'lights',
  ),
  _Sig(
    'light_auto_switch',
    'Light.LIGHT_AUTO_SWITCH',
    description: 'Auto-light master switch',
    category: 'lights',
  ),
  _Sig(
    'light_emergency_warn',
    'Light.LIGHT_EMERGENCY_WARNING_LIGHT_STATE',
    description: 'Hazard / emergency warning lights state',
    category: 'lights',
    threeD: true,
  ),
  _Sig(
    'light_double_flash_cmd',
    'Light.LIGHT_CMD_DOUBLE_FLASH_STATE',
    description: 'Commanded hazard flash state',
    category: 'lights',
  ),
  _Sig(
    'light_drl_cmd',
    'Light.LIGHT_CMD_DAY_RUNNING_LIGHT_STATE',
    description: 'Commanded DRL state',
    category: 'lights',
    threeD: true,
  ),
  _Sig(
    'light_reverse_cmd',
    'Light.LIGHT_CMD_REVERSING_LIGHT_STATE',
    description: 'Commanded reversing-light state',
    category: 'lights',
    threeD: true,
  ),
  _Sig(
    'light_stop_cmd',
    'Light.LIGHT_CMD_STOP_LIGHT_STATE',
    description: 'Commanded brake-light state',
    category: 'lights',
    threeD: true,
  ),
  _Sig(
    'light_sequential_cmd',
    'Light.LIGHT_CMD_SEQUENTIAL_STATE',
    description: 'Commanded sequential indicator pattern',
    category: 'lights',
  ),
  _Sig(
    'light_daytime_status',
    'Light.LIGHT_DAYTIME_POSITION_LAMP_STATUS',
    description: 'Daytime position-lamp status',
    category: 'lights',
  ),
  _Sig(
    'light_front_fog_status',
    'Light.LIGHT_FRONT_FOG_LAMP_STATUS',
    description: 'Front fog lamp detailed status',
    category: 'lights',
  ),
  _Sig(
    'light_rear_fog_lamps',
    'Light.LIGHT_REAR_FOG_LAMPS',
    description: 'Rear fog lamps detailed state',
    category: 'lights',
  ),
  _Sig(
    'light_front_middle_pos',
    'Light.LIGHT_FRONE_MIDDLE_POSITION_LIGHT',
    description: 'Front-middle position light state',
    category: 'lights',
  ),
  _Sig(
    'light_front_center_pos',
    'Light.LIGHT_FRONT_CENTER_POSITION_LIGHTS_STATUS',
    description: 'Front-centre position lights status',
    category: 'lights',
  ),
  _Sig(
    'light_highlight_pos',
    'Light.LIGHT_HIGHLIGHT_POSITION_LIGHT',
    description: 'Highlight position-light state',
    category: 'lights',
  ),
  _Sig(
    'light_left_wing_pos',
    'Light.LIGHT_LEFT_FRONT_POSITION_SPATIOTEMPORAL_WING_LIGHT_STATUS',
    description: 'Left front spatiotemporal wing light',
    category: 'lights',
  ),
  _Sig(
    'light_right_wing_pos',
    'Light.LIGHT_RIGHT_FRONT_POSITION_SPATIOTEMPORAL_WING_LIGHT_STATUS',
    description: 'Right front spatiotemporal wing light',
    category: 'lights',
  ),
  _Sig(
    'light_position_display',
    'Light.LIGHT_POSITION_LIGHT_DISPLAY_FEEDBACK',
    description: 'Position-light display feedback',
    category: 'lights',
  ),
  _Sig(
    'light_intelligent_position',
    'Light.LIGHT_INTELLIGENT_POSITION_LIGHT_SCHEME_FEEDBACK',
    description: 'Intelligent position light scheme feedback',
    category: 'lights',
  ),
  _Sig(
    'light_turn_state',
    'Light.LIGHT_TURN_SIGNAL_LIGHTS_STATE',
    description: 'Combined turn-signal lights state',
    category: 'lights',
    threeD: true,
  ),
  _Sig(
    'light_turn_left_alt',
    'Light.LIGHT_LEFT_TURN_SIGNAL',
    description: 'Left turn signal state (alternate signal)',
    category: 'lights',
  ),
  _Sig(
    'light_turn_right_alt',
    'Light.LIGHT_RIGHT_TURN_SIGNAL',
    description: 'Right turn signal state (alternate signal)',
    category: 'lights',
  ),
  _Sig(
    'light_turn_switch_state',
    'Light.LIGHT_TURN_SIGNAL_LIGHT_SWITCH_STATE',
    description: 'Turn-signal switch position',
    category: 'lights',
  ),
  _Sig(
    'light_intelligent_turn',
    'Light.LIGHTS_INTELLIGENT_TURN_SIGNAL_STATUS',
    description: 'Intelligent turn-signal status',
    category: 'lights',
  ),
  _Sig(
    'light_combination_switch',
    'Light.LIGHTS_COMBINATION_SWITCH_TYPE',
    description: 'Stalk combination switch type',
    category: 'lights',
  ),
  _Sig(
    'light_steering_lever',
    'Light.LIGHT_STEERING_LEVER_COMBINATION_SWITCH_TYPE',
    description: 'Steering lever combination switch type',
    category: 'lights',
  ),
  _Sig(
    'light_pedestrian_comity',
    'Light.LIGHTS_PEDESTRAIN_COMITY_FUNCTION_STATUS',
    description: 'Pedestrian-comity (yield) lighting state',
    category: 'lights',
  ),
  _Sig(
    'light_adas_indicator',
    'Light.LIGHTS_ADAS_INDICATOR_LIGHT_STATUS',
    description: 'ADAS indicator light status',
    category: 'lights',
  ),
  _Sig(
    'light_day_night_mode',
    'Light.LIGHT_DAY_NIGHT_MODE_STATUS',
    description: 'Day / night mode status',
    category: 'lights',
  ),
  _Sig(
    'light_drl_status',
    'Light.LIGHT_DAY_RUNNING_LIGHT_AUTO_STATE',
    description: 'Daytime running light auto state (alias)',
    category: 'lights',
  ),
  _Sig(
    'light_cargo_switch',
    'Light.LIGHT_CARGO_LIGHT_SWITCH',
    description: 'Cargo-area light switch state',
    category: 'lights',
  ),
  _Sig(
    'light_top_config',
    'Light.LIGHTS_TOP_LIGHT_CONFIG',
    description: 'Top-light hardware configuration',
    category: 'lights',
  ),
  _Sig(
    'light_left_welcome_mat',
    'Light.LIGHTS_LEFT_WELCOME_MAT',
    description: 'Left puddle/welcome-mat light state',
    category: 'lights',
  ),
  _Sig(
    'light_right_welcome_mat',
    'Light.LIGHTS_RIGHT_WELCOME_MAT',
    description: 'Right puddle/welcome-mat light state',
    category: 'lights',
  ),
  _Sig(
    'light_unlock_welcome',
    'Light.LIGHT_UNLOCK_WELCOME_SWITCH',
    description: 'Unlock-welcome animation enabled',
    category: 'lights',
  ),
  _Sig(
    'light_lock_welcome',
    // catalog.tsv ships LIGHT_LOCK_WELCOME_STATUS (the readable state), not
    // a *_SWITCH — the old name resolved to nothing, so this gate field
    // read null. (Unlock side has no *_STATUS variant; see the catalog
    // drift guard's allowlist.)
    'Light.LIGHT_LOCK_WELCOME_STATUS',
    description: 'Lock-welcome animation enabled',
    category: 'lights',
  ),
  _Sig(
    'light_find_car_welcome',
    'Light.LIGHTS_FIND_CAR_WELCOME_SWITCH',
    description: 'Find-my-car welcome flash enabled',
    category: 'lights',
  ),
  _Sig(
    'light_flash_and_horn',
    'Light.LIGHTS_FLASHING_LIGHT_AND_HORN',
    description: 'Flash-lights-and-horn (find-car) trigger',
    category: 'lights',
  ),
  _Sig(
    'light_find_car_status',
    'Light.LIGHT_FIND_CAR_WELCOME_STATUS',
    description: 'Find-car welcome current status',
    category: 'lights',
  ),
  _Sig(
    'atmos_main_switch',
    'Light.LIGHT_ATMOSPHERE_MAIN_SWITCH',
    description: 'Ambient-lights master switch',
    category: 'cabin',
    writeable: true,
    writeAction: 'lights.atmos.master.toggle',
    // The textproto splits atmos on/off into two action_ids (atmos.on
    // / atmos.off); the registry's `comfort.atmos` resolves to the
    // right one based on `field`. `wireActionId` here records the
    // canonical entry for parity-test purposes; full toggle handling
    // lives in `comfort.dart`.
    wireActionId: 'comfort.atmos.on',
  ),
  _Sig(
    'atmos_custom_mode',
    'Light.LIGHT_ATMOSPHERE_CUSTOM_MODE',
    description: 'Ambient custom mode active',
    category: 'cabin',
  ),
  _Sig(
    'atmos_custom_color',
    'Light.LIGHT_ATMOSPHERE_CUSTOM_COLOR',
    description: 'Ambient custom colour value',
    category: 'cabin',
  ),
  _Sig(
    'atmos_custom_bright',
    'Light.LIGHT_ATMOSPHERE_CUSTOM_BRIGHTNESS',
    description: 'Ambient custom brightness',
    category: 'cabin',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'atmos_env_mode',
    'Light.LIGHT_ATMOSPHERE_ENVIRNMENTAL_MODE_SWITCH',
    description: 'Ambient environmental mode',
    category: 'cabin',
  ),
  _Sig(
    'atmos_warn_aux',
    'Light.LIGHT_ATMOSPHERE_WARNING_AUXILIARY_SWITCH',
    description: 'Ambient warning auxiliary switch',
    category: 'cabin',
  ),
  _Sig(
    'atmos_welcome_celemony',
    'Light.LIGHT_ATMOSPHERE_WELCOME_CELEMONY_SWITCH',
    description: 'Ambient welcome ceremony switch',
    category: 'cabin',
  ),
  _Sig(
    'atmos_night_weaken',
    'Light.LIGHT_ATMOSPHERE_LIGHT_NIGHT_WEAKEN_MODE',
    description: 'Ambient night-weaken mode',
    category: 'cabin',
  ),
  _Sig(
    'atmos_ui_display',
    'Light.LIGHT_ATMOSPHERE_LAMP_UI_DISPLAY',
    description: 'Ambient-lamp UI display state',
    category: 'cabin',
  ),
  _Sig(
    'atmos_front_foot_red',
    'Light.LIGHT_FRONT_FOOT_ATMOSPHERE_LAMP_RED',
    description: 'Front foot-well ambient lamp red component',
    category: 'cabin',
  ),
  _Sig(
    'atmos_front_foot_green',
    'Light.LIGHT_FRONT_FOOT_ATMOSPHERE_LAMP_GREEN',
    description: 'Front foot-well ambient lamp green component',
    category: 'cabin',
  ),
  _Sig(
    'atmos_front_foot_blue',
    'Light.LIGHT_FRONT_FOOT_ATMOSPHERE_LAMP_BLUE',
    description: 'Front foot-well ambient lamp blue component',
    category: 'cabin',
  ),
  _Sig(
    'atmos_front_foot_bright',
    'Light.LIGHT_FRONT_FOOT_ATMOSPHERE_LAMP_BRIGHTNESS',
    description: 'Front foot-well ambient brightness',
    category: 'cabin',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'atmos_star_roof_mode',
    'Light.LIGHT_STAR_ROOF_ATMOSPHERE_MODE',
    description: 'Star-roof ambient mode',
    category: 'cabin',
  ),
  _Sig(
    'atmos_star_roof_switch',
    'Light.LIGHT_STAR_ROOF_ATMOSPHERE_SWITCH_STATUS',
    description: 'Star-roof ambient switch state',
    category: 'cabin',
  ),
  _Sig(
    'atmos_star_sky_bright',
    'Light.LIGHT_STAR_SKY_ATMOSPHERE_LAMP_BRIGHTNESS',
    description: 'Star-sky ambient brightness',
    category: 'cabin',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'atmos_star_sky_color',
    'Light.LIGHT_STAR_SKY_ATMOSPHERE_LAMP_COLOR',
    description: 'Star-sky ambient colour',
    category: 'cabin',
  ),
  _Sig(
    'atmos_star_ring_bright',
    'Light.LIGHT_STAR_RING_ATMOSPHERE_LAMP_BRIGHTNESS',
    description: 'Star-ring ambient brightness',
    category: 'cabin',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'atmos_star_ring_color',
    'Light.LIGHT_STAR_RING_ATMOSPHERE_LAMP_COLOR',
    description: 'Star-ring ambient colour',
    category: 'cabin',
  ),
  _Sig(
    'atmos_uav_state',
    'Light.LIGHT_UAV_ATMOSPHERE_LIGHT_STATUS',
    description: 'UAV (drone) ambient light status',
    category: 'cabin',
  ),
  _Sig(
    'inside_light_l_mid_status',
    'Light.LIGHT_LEFT_MIDDLE_INSIDE_LIGHT_STATUS',
    description: 'Left middle interior light status',
    category: 'lights',
  ),
  _Sig(
    'inside_light_r_mid_status',
    'Light.LIGHT_RIGHT_MIDDLE_INSIDE_LIGHT_STATUS',
    description: 'Right middle interior light status',
    category: 'lights',
  ),
  _Sig(
    'inside_light_l_mid_bright',
    'Light.LIGHT_LEFT_MIDDLE_INSIDE_LIGHT_BRIGHTNESS',
    description: 'Left middle interior light brightness',
    category: 'lights',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'inside_light_r_mid_bright',
    'Light.LIGHT_RIGHT_MIDDLE_INSIDE_LIGHT_BRIGHTNESS',
    description: 'Right middle interior light brightness',
    category: 'lights',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'inside_light_l_mid_spot',
    'Light.LIGHT_LEFT_MIDDLE_INSIDE_LIGHT_SPOT_POSITION',
    description: 'Left middle interior light spot position',
    category: 'lights',
  ),
  _Sig(
    'inside_light_r_mid_spot',
    'Light.LIGHT_RIGHT_MIDDLE_INSIDE_LIGHT_SPOT_POSITION',
    description: 'Right middle interior light spot position',
    category: 'lights',
  ),
  _Sig(
    'light_projection_mode',
    'Light.LIGHTS_PROJECTION_PLAY_MODE_STATUS',
    description: 'Pixel headlight projection play mode',
    category: 'lights',
  ),
  _Sig(
    'light_projection_scale',
    'Light.LIGHTS_PROJECTION_SCALE',
    description: 'Pixel headlight projection scale',
    category: 'lights',
  ),
  _Sig(
    'light_projection_area',
    'Light.LIGHTS_PROJECT_AREA_STATE',
    description: 'Pixel headlight projection area state',
    category: 'lights',
  ),
  _Sig(
    'light_pixel_cal',
    'Light.LIGHTS_PIXEL_ONEKEY_CALIBRATION',
    description: 'Pixel headlight one-key calibration state',
    category: 'lights',
  ),
  _Sig(
    'light_pixel_calibration_result',
    'Light.LIGHTS_PIXEL_CALIBRATION_VERIFICATION_RESULT',
    description: 'Pixel calibration verification result',
    category: 'lights',
  ),
  _Sig(
    'light_pixel_sound_track',
    'Light.LIGHTS_PIXEL_SOUND_TRACK_STATE',
    description: 'Pixel-headlight soundtrack play state',
    category: 'lights',
  ),
  _Sig(
    'light_pixel_projection_cfg',
    'Light.LIGHTS_PIXEL_PROJECTION_LIGHT_CONFIG',
    description: 'Pixel projection light configuration',
    category: 'lights',
  ),
  _Sig(
    'light_width_line_projection',
    'Light.LIGHTS_WIDTH_LINE_PROJECTION_STATUS',
    description: 'Width-line projection status',
    category: 'lights',
  ),
  _Sig(
    'light_costomize_projection',
    'Light.LIGHTS_COSTOMIZE_PROJECTION_STATE',
    description: 'Customised projection state',
    category: 'lights',
  ),
  _Sig(
    'light_navigator_sub',
    'Light.LIGHTS_NAVIGATOR_SUBSIDIARY_STATUS',
    description: 'Navigation-light subsidiary status',
    category: 'lights',
  ),
  _Sig(
    'light_traffic_flow',
    'Light.LIGHTS_TRAFFIC_FLOW',
    description: 'Pixel-headlight traffic-flow visual mode',
    category: 'lights',
  ),
  _Sig(
    'light_lock_welcome_status',
    'Light.LIGHT_LOCK_WELCOME_STATUS',
    description: 'Lock-welcome animation current status',
    category: 'lights',
  ),
  _Sig(
    'light_dynamic_welcome_done',
    'Light.LIGHT_DYNAMIC_WELCOME_FINISH_FLAG',
    description: 'Dynamic welcome animation done flag',
    category: 'lights',
  ),

  // ── Charging (expansion) ──────────────────────────────────────
  _Sig(
    'chg_appointment_year',
    'Charging.CHARGING_APPOINTMENT_CAR_YEAR',
    description: 'Scheduled charge appointment year',
  ),
  _Sig(
    'chg_appointment_month',
    'Charging.CHARGING_APPOINTMENT_CAR_MONTH',
    description: 'Scheduled charge appointment month',
  ),
  _Sig(
    'chg_appointment_day',
    'Charging.CHARGING_APPOINTMENT_CAR_DAY',
    description: 'Scheduled charge appointment day',
  ),
  _Sig(
    'chg_appointment_hour',
    'Charging.CHARGING_APPOINTMENT_CAR_HOUR',
    description: 'Scheduled charge appointment hour',
    range: IntRange(0, 23),
  ),
  _Sig(
    'chg_appointment_minute',
    'Charging.CHARGING_APPOINTMENT_CAR_MINUTE',
    description: 'Scheduled charge appointment minute',
    range: IntRange(0, 59),
  ),
  _Sig(
    'chg_appointment_end_soc',
    'Charging.CHARGING_APPOINTMENT_END_SOC',
    description: 'Scheduled charge target SoC',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'chg_appointment_start_hour',
    'Charging.CHARGING_APPOINTMENT_START_TIME_HOUR',
    description: 'Scheduled charge start-time hour',
    range: IntRange(0, 23),
  ),
  _Sig(
    'chg_appointment_start_min',
    'Charging.CHARGING_APPOINTMENT_START_TIME_MINUTE',
    description: 'Scheduled charge start-time minute',
    range: IntRange(0, 59),
  ),
  _Sig(
    'chg_appointment_end_hour',
    'Charging.CHARGING_APPOINTMENT_END_TIME_HOUR',
    description: 'Scheduled charge end-time hour',
    range: IntRange(0, 23),
  ),
  _Sig(
    'chg_appointment_end_min',
    'Charging.CHARGING_APPOINTMENT_END_TIME_MINUTE',
    description: 'Scheduled charge end-time minute',
    range: IntRange(0, 59),
  ),
  _Sig(
    'chg_appointment_time_opt',
    'Charging.CHARGING_CHARGE_APPOINTMET_TIME_OPTION',
    description: 'Charge appointment time option (once / daily / weekly)',
  ),
  _Sig(
    'chg_appointment_quit_reason',
    'Charging.CHARGING_APPOINTMENT_QUTI_REASON',
    description: 'Reason scheduled charge was aborted',
  ),
  _Sig(
    'chg_appointment_ac_start_fail',
    'Charging.CHARGING_CAR_APPOINTMENT_AC_STATR_FAIL_REASON',
    description: 'Scheduled AC charge start-fail reason',
  ),
  _Sig(
    'chg_battery_device_state',
    'Charging.CHARGING_BATTERRY_DEVICE_STATE',
    description: 'Battery device charging state',
  ),
  _Sig(
    'chg_battery_type',
    'Charging.CHARGING_BATTERY_TYPE',
    description: 'Battery chemistry / type code',
  ),
  _Sig(
    'chg_battery_preheat_sign',
    'Charging.CHARGING_BATTERY_PREHEAT_MODE_SIGN',
    description: 'Battery preheat mode active',
  ),
  _Sig(
    'chg_battery_save_mode',
    'Charging.CHARGING_BATTERY_ENERGY_SAVING_MODE',
    description: 'Battery energy-saving mode active',
  ),
  _Sig(
    'chg_charge_power_dd',
    'Charging.CHARGING_CHARGE_POWER_DD',
    description: 'Driver-display charging power readout',
    units: 'kw',
  ),
  _Sig(
    'chg_charge_power_dm',
    'Charging.CHARGING_CHARGE_POWER_DM',
    description: 'Domain-controller charging power readout',
    units: 'kw',
  ),
  _Sig(
    'chg_charge_percent_dd',
    'Charging.CHARGING_CHARGE_PERCENT_DD',
    description: 'Driver-display charging percent',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'chg_charge_rest_h_dd',
    'Charging.CHARGING_CHARGE_REST_HOUR_DD',
    description: 'Driver-display remaining hours to full',
    units: 'hours',
  ),
  _Sig(
    'chg_charge_rest_m_dd',
    'Charging.CHARGING_CHARGE_REST_MINUTE_DD',
    description: 'Driver-display remaining minutes to full',
    units: 'minutes',
    range: IntRange(0, 59),
  ),
  _Sig(
    'chg_charge_rest_total_dd',
    'Charging.CHARGING_CHARGE_REST_TIME_DD',
    description: 'Driver-display total remaining time to full',
  ),
  _Sig(
    'chg_charge_display_dd',
    'Charging.CHARGING_CHARGE_DISPLAY_DD',
    description: 'Driver-display charging visualisation state',
  ),
  _Sig(
    'chg_charge_schedule_dd',
    'Charging.CHARGING_CHARGE_SCHEDULE_DISPLAY_DD',
    description: 'Driver-display charge-schedule visualisation',
  ),
  _Sig(
    'chg_charge_notice_dd',
    'Charging.CHARGING_CHARGE_NOTICE_DD',
    description: 'Driver-display charging notice text id',
  ),
  _Sig(
    'chg_dischg_warning',
    'Charging.CHARGING_CHARGE_DISCHARGE_WARNING',
    description: 'Charge / discharge warning code',
  ),
  _Sig(
    'chg_temp_ctl_state',
    'Charging.CHARGING_CHARGE_TEMPERATURE_CTL_STATE',
    description: 'Battery temperature control during charge',
  ),
  _Sig(
    'chg_temp_ctl_online',
    'Charging.CHARGING_CHARGE_TEMPERATURE_CTL_ONLINE',
    description: 'Temperature-control-online flag',
  ),
  _Sig(
    'chg_soc_limit',
    'Charging.CHARGING_CHARGE_SOC_LIMIT',
    description: 'Charge SoC limit',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'chg_limit_cfg',
    'Charging.CHARGING_CHARGE_LIMIT_FUNCTION_CONFIG_STATUS',
    description: 'Charge-limit feature configured',
  ),
  _Sig(
    'chg_port_lock',
    'Charging.CHARGING_CHARGE_PORT_LOCK_REBACK',
    description: 'Charge-port lock feedback',
  ),
  _Sig(
    'chg_ac_current_type',
    'Charging.CHARGING_AC_CHARGING_CURRENT_TYPE',
    description: 'AC charging current type',
  ),
  _Sig(
    'chg_ac_cover',
    'Charging.CHARGING_AC_COVER_STATE',
    description: 'AC charging port cover state',
  ),
  _Sig(
    'chg_v2v_cfg',
    'Charging.CHARGING_AC_VTOV_DISCHARGE_FUNC_CONFIG',
    description: 'V2V (vehicle-to-vehicle) discharge configured',
  ),
  _Sig(
    'chg_ac_v2v_cfg',
    'Charging.CHARGING_ALTERNATING_CURRENT_VTOV_CONFIG',
    description: 'AC V2V configured flag',
  ),
  _Sig(
    'chg_vehicle_battery_type',
    'Charging.CHARGING_CHARGE_VEHICLE_BATTERY_TYPE',
    description: 'Charger-side vehicle battery type',
  ),
  _Sig(
    'chg_needed_current',
    'Charging.CHARGING_CHARGE_VEHICLE_NEEDED_CURRENT',
    description: 'Vehicle requested charge current',
    units: 'amps',
  ),
  _Sig(
    'chg_needed_voltage',
    'Charging.CHARGING_CHARGE_VEHICLE_NEEDED_VOLTAGE',
    description: 'Vehicle requested charge voltage',
    units: 'volts',
  ),
  _Sig(
    'chg_bms_interface',
    'Charging.CHARGING_BMS_CHARGING_INTERFACE',
    description: 'BMS charging interface code',
  ),
  _Sig(
    'chg_bms_pile_operator',
    'Charging.CHARGING_BMS_PILE_OPERATOR',
    description: 'Charging-pile operator id from BMS',
  ),
  _Sig(
    'chg_battery_cell_num',
    'Charging.CHARGING_BATTERY_VOLTAGE_CELL_NUM',
    description: 'Number of cells reported by charger',
  ),
  _Sig(
    'chg_battery_actual_num',
    'Charging.CHARGING_ACTUAL_BATTERY_NUMBER',
    description: 'Actual battery pack count',
  ),
  _Sig(
    'chg_wireless_l_pwr',
    'Charging.CHARGING_CHARGE_WIRELESS_CHARGING_L_POWER',
    description: 'Left wireless-pad delivered power',
    units: 'watts',
  ),
  _Sig(
    'chg_wireless_r_pwr',
    'Charging.CHARGING_CHARGE_WIRELESS_CHARGING_R_POWER',
    description: 'Right wireless-pad delivered power',
    units: 'watts',
  ),
  _Sig(
    'chg_wireless_r_state',
    'Charging.CHARGING_CHARGE_WIRELESS_CHARGING_R_STATE',
    description: 'Right wireless-pad device state',
  ),
  _Sig(
    'chg_wireless_r_state_mode',
    'Charging.CHARGING_CHARGE_WIRELESS_CHARGING_R_STATE_MODE',
    description: 'Right wireless-pad state mode',
  ),
  _Sig(
    'chg_wireless_state',
    'Charging.CHARGING_CHARGE_WIRELESS_CHARGING_STATE',
    description: 'Wireless charging combined state',
  ),
  _Sig(
    'chg_wireless_power_dual',
    'Charging.CHARGING_CHARGE_WIRELESS_CHARGING_POWER_DUAL',
    description: 'Wireless dual-pad combined power',
    units: 'watts',
  ),
  _Sig(
    'chg_charger_pad_remain',
    'Charging.CHARGING_DETACHABLE_PAD_REMAIN_STATUS',
    description: 'Detachable wireless pad remain status',
  ),

  // ── Propulsion (expansion) ────────────────────────────────────
  _Sig(
    'motor_input_voltage',
    'Engine.ENGINE_MOTOR_INPUT_VOLTAGE',
    description: 'Motor controller input voltage',
    units: 'volts',
  ),
  _Sig(
    'engine_indicated_torque',
    'Engine.ENGINE_INDICATED_TORQUE',
    description: 'Engine indicated torque',
  ),
  _Sig(
    'engine_oil_level',
    'Engine.ENGINE_OIL_LEVEL',
    description: 'Engine oil level',
  ),
  _Sig(
    'engine_coolant_level',
    'Engine.ENGINE_COOLANT_LEVEL',
    description: 'Engine coolant level',
  ),
  _Sig(
    'engine_charge_power',
    'Engine.ENGINE_CHARGE_POWER',
    description: 'Engine-driven charge power (REEV / series mode)',
    units: 'kw',
  ),
  _Sig(
    'engine_catalyst_heat',
    'Engine.ENGINE_CATALYST_HEATING_FLAG',
    description: 'Catalyst heating active',
  ),
  _Sig(
    'engine_code',
    'Engine.ENGINE_CODE',
    description: 'Engine code (variant)',
  ),
  _Sig(
    'engine_after_cool_sw',
    'Engine.ENGINE_AFTER_DRIVING_COOL_SWITCH',
    description: 'After-drive cooling switch state',
  ),
  _Sig(
    'engine_cross_country_radiate',
    'Engine.ENGINE_CROSS_COUNTRY_RADIATING_SWITCH_STATUS',
    description: 'Off-road radiator-fan switch status',
  ),
  _Sig(
    'engine_custom_sub_mode',
    'Engine.ENGINE_CUSTOM_AUTUAL_SUB_MODE',
    description: 'Active custom drive sub-mode',
  ),
  _Sig(
    'engine_drive_force_adjust',
    'Engine.ENGINE_DRIVE_FORCE_ADJUST',
    description: 'Drive-force adjustment level',
  ),
  _Sig(
    'engine_drive_force_sw',
    'Engine.ENGINE_DRIVE_FORCE_ADJUST_SWITCH',
    description: 'Drive-force adjustment switch',
  ),
  _Sig(
    'engine_advanced_handling_sw',
    'Engine.ENGINE_ADVANCED_HANDLING_SWITCH',
    description: 'Advanced handling mode switch',
  ),
  _Sig(
    'engine_feedback_level',
    'Engine.ENGINE_FEEDBACK_ABILITY_TARGET_LEVEL',
    description: 'Regen feedback target level',
  ),
  _Sig(
    'engine_feedback_sw',
    'Engine.ENGINE_FEEDBACK_ABILITY_TARGET_LEVEL_SWITCH',
    description: 'Regen feedback switch',
  ),
  _Sig(
    'engine_axle_torque_alloc',
    'Engine.ENGINE_FRONT_AXLE_TORQUE_TARGET_ALLOCATION_PROPORTION',
    description: 'Front axle torque allocation proportion',
  ),
  _Sig(
    'engine_axle_torque_alloc_sw',
    'Engine.ENGINE_FRONT_REAR_AXLE_TORQUE_ALLOCATION_SWITCH',
    description: 'Front/rear axle torque allocation switch',
  ),
  _Sig(
    'motor_lf_actual_wheel_torque',
    'Engine.ENGINE_LEFT_FRONT_MOTOR_ACTUAL_WHEEL_TORQUE',
    description: 'Left-front motor actual wheel torque',
  ),
  _Sig(
    'motor_lr_actual_wheel_torque',
    'Engine.ENGINE_LEFT_REAR_MOTOR_ACTUAL_WHEEL_TORQUE',
    description: 'Left-rear motor actual wheel torque',
  ),
  _Sig(
    'motor_lf_igbt_temp',
    'Engine.ENGINE_LEFT_FRONT_MACHINE_IGBT_TEMP_LEVEL',
    description: 'Left-front motor IGBT temperature level',
  ),
  _Sig(
    'motor_lf_temp',
    'Engine.ENGINE_LEFT_FRONT_MACHINE_TEMP_LEVEL',
    description: 'Left-front motor housing temp level',
  ),
  _Sig(
    'motor_lr_igbt_temp',
    'Engine.ENGINE_LEFT_REAR_MACHINE_IGBT_TEMP_LEVEL',
    description: 'Left-rear motor IGBT temperature level',
  ),
  _Sig(
    'motor_lr_temp',
    'Engine.ENGINE_LEFT_REAR_MACHINE_TEMP_LEVEL',
    description: 'Left-rear motor housing temp level',
  ),
  _Sig(
    'engine_has_voice_sim',
    'Engine.ENGINE_HAS_ENGINE_VOICE_SIMULATOR',
    description: 'Vehicle has engine voice simulator (0 no, 1 yes)',
  ),
  _Sig(
    'engine_has_voice_source',
    'Engine.ENGINE_HAS_ENGINE_VOICE_SOURCE',
    description: 'Engine voice source available',
  ),
  _Sig(
    'engine_power_response',
    'Engine.ENGINE_POWER_RESPONSE_ACTUAL_STATUS',
    description: 'Power-response actual status',
  ),
  _Sig(
    'energy_state_2',
    'Energy.ENERGY_STATE',
    description: 'Energy subsystem state (alias for energy_state)',
  ),
  _Sig(
    'energy_operation_mode',
    'Energy.ENERGY_OPERATION_MODE',
    description: 'Energy operation mode (EV / HEV / charging / discharging)',
  ),
  _Sig(
    'energy_mode_instrument',
    'Energy.ENERGY_MODE_INSTRUMENT',
    description: 'Energy mode shown on instrument cluster',
  ),
  _Sig(
    'energy_ev_hev_shift',
    'Energy.ENERGY_EV_HEV_SHIFT_KEY',
    description: 'EV/HEV mode shift key state',
  ),
  _Sig(
    'energy_road_surface',
    'Energy.ENERGY_ROAD_SURFACE_KIND',
    description: 'Detected road-surface kind',
  ),
  _Sig(
    'energy_road_surface_mode',
    'Energy.ENERGY_ROAD_SURFACE_MODE',
    description: 'Road-surface-driven drive mode',
  ),
  _Sig(
    'energy_4wd_low_speed',
    'Energy.ENERGY_FOUR_WHEEL_DRIVE_LOW_SPEED_MODE_FLAG',
    description: '4WD low-speed mode active',
  ),
  _Sig(
    'energy_high_voltage',
    'Energy.ENERGY_HIGH_SIDE_VOLTAGE',
    description: 'High-side (HV) bus voltage',
    units: 'volts',
  ),
  _Sig(
    'energy_high_current',
    'Energy.ENERGY_HIGH_SIDE_CURRENT',
    description: 'High-side (HV) bus current',
    units: 'amps',
  ),
  _Sig(
    'energy_low_voltage',
    'Energy.ENERGY_LOW_SIDE_VOLTAGE',
    description: 'Low-side (12V) bus voltage',
    units: 'volts',
  ),
  _Sig(
    'energy_low_side_v',
    'Energy.ENERGY_LOW_VOLTAGE_SIDE_VOLTAGE',
    description: 'Low-voltage side voltage',
    units: 'volts',
  ),
  _Sig(
    'energy_low_side_a',
    'Energy.ENERGY_LOW_VOLTAGE_SIDE_CURRENT',
    description: 'Low-voltage side current',
    units: 'amps',
  ),
  _Sig(
    'energy_low_voltage_limit',
    'Energy.ENERGY_LOW_VOLTAGE_POWER_LIMIT',
    description: 'Low-voltage power limit',
    units: 'watts',
  ),
  _Sig(
    'energy_regen_state',
    'Energy.ENERGY_POWER_GENERATION_STATE',
    description: 'Regenerative power generation state',
  ),
  _Sig(
    'energy_dc_bus_volt',
    'Energy.ENERGY_DC_BUS_VOLTAGE',
    description: 'DC bus voltage',
    units: 'volts',
  ),
  _Sig(
    'energy_dc_work_mode',
    'Energy.ENERGY_DC_WORK_MODE',
    description: 'DC converter work mode',
  ),
  _Sig(
    'energy_dc_port_temp',
    'Energy.ENERGY_DC_CHARGING_PORT_TEMP',
    description: 'DC charging port temperature',
    units: 'celsius',
  ),
  _Sig(
    'energy_trip_avg_elec',
    'Energy.ENERGY_CURRENT_ITINERARY_AVERAGE_ELECTRICITY_CONSUMPTION',
    description: 'Current trip average electric consumption',
  ),
  _Sig(
    'energy_trip_avg_fuel',
    'Energy.ENERGY_CURRENT_ITINERARY_AVERAGE_FUEL_CONSUMPTION',
    description: 'Current trip average fuel consumption',
  ),
  _Sig(
    'energy_trip_avg_equiv',
    'Energy.ENERGY_CURRENT_ITINERARY_EQUIVALENT_AVERAGE_ENERGY_CONSUMPTION',
    description: 'Current trip equivalent average energy consumption',
  ),
  _Sig(
    'energy_trip_ac_pct',
    'Energy.ENERGY_CURRENT_ITINERARY_AC_CONSUMPTION_PERCENT',
    description: 'Current trip AC consumption percentage',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'energy_trip_drive_pct',
    'Energy.ENERGY_CURRENT_ITINERARY_DRIVE_CONSUMPTION_PERCENT',
    description: 'Current trip drive consumption percentage',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'energy_trip_elec_pct',
    'Energy.ENERGY_CURRENT_ITINERARY_ELECTRIC_EQUIPMENT_CONSUMPTION_PERCENT',
    description: 'Current trip electric-equipment consumption percentage',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'energy_trip_other_pct',
    'Energy.ENERGY_CURRENT_ITINERARY_OTHER_CONSUMPTION_PERCENT',
    description: 'Current trip other consumption percentage',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'energy_50km_ac_pct',
    'Energy.ENERGY_RECENTLY_50KM_AC_CONSUMPTION_PERCENT',
    description: 'Last 50km AC consumption percentage',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'energy_50km_drive_pct',
    'Energy.ENERGY_RECENTLY_50KM_DRIVE_CONSUMPTION_PERCENT',
    description: 'Last 50km drive consumption percentage',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'energy_50km_elec_pct',
    'Energy.ENERGY_RECENTLY_50KM_ELECTRIC_EQUIPMENT_CONSUMPTION_PERCENT',
    description: 'Last 50km electric-equipment consumption percentage',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'energy_50km_other_pct',
    'Energy.ENERGY_RECENTLY_50KM_OTHER_CONSUMPTION_PERCENT',
    description: 'Last 50km other consumption percentage',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'gearbox_epb_alt',
    'Gearbox.GEARBOX_EPB_STATE',
    description: 'EPB state (alias of epb_state)',
  ),

  // ── Dynamics (expansion) ──────────────────────────────────────
  _Sig(
    'speed_brake_pedal',
    'Bodywork.BODYWORK_BRAKE_PEDAL_STATE',
    description: 'Brake-pedal state (0 released, 1 pressed)',
    category: 'dynamics',
  ),
  _Sig(
    'steering_wheel_angle',
    'Bodywork.BODYWORK_STEERING_WHEEL_ANGEL',
    description: 'Steering wheel angle (degrees, signed)',
  ),
  _Sig(
    'steering_wheel_speed',
    'Bodywork.BODYWORK_STEERING_WHEEL_SPEED',
    description: 'Steering wheel rate-of-change',
  ),
  _Sig(
    'steering_wheel_heat',
    'Setting.SET_STEERING_WHEEL_HEAT_STATE',
    description: 'Steering-wheel heating state',
    writeable: true,
    writeAction: 'steering.heat.toggle',
  ),
  _Sig(
    'steering_wheel_heat_gear',
    'Setting.SET_AUTO_STEER_WHEEL_HEATING_GEAR',
    description: 'Steering-wheel heating gear level',
  ),
  _Sig(
    'steering_wheel_heat_mode',
    'Setting.SET_AUTO_STEER_WHEEL_HEATING_MODE',
    description: 'Steering-wheel heating mode',
  ),
  _Sig(
    'steering_has_power',
    'Setting.SET_HAS_POWER_STEERING',
    description: 'Vehicle has power steering (0 no, 1 yes)',
  ),
  _Sig(
    'steering_has_vibration',
    'Setting.SET_HAS_STEERING_WHEEL_VIBRATION_FUNTION',
    description: 'Vehicle has steering-wheel vibration feedback',
  ),
  _Sig(
    'steering_mode',
    'Setting.SET_STEERING_WHEEL_MODE',
    description: 'Steering mode (comfort / sport / etc.)',
  ),
  _Sig(
    'steering_front_angle',
    'Setting.SETTING_FRONT_WHEEL_STEERING_ANGLE',
    description: 'Front wheel steering angle',
  ),
  _Sig(
    'slope_ad_value',
    'Sensor.SENSOR_AUTO_SLOPE',
    description: 'Slope sensor reading (alias of sensor_slope)',
    category: 'dynamics',
  ),
  _Sig(
    'yaw_rate',
    'Sensor.SENSOR_YAW_RATE_SIGNAL',
    description: 'Yaw rate sensor signal',
    category: 'dynamics',
  ),
  _Sig(
    'yaw_status',
    'Sensor.SENSOR_YAW_RATE_STATUS',
    description: 'Yaw rate sensor status',
    category: 'dynamics',
  ),
  _Sig(
    'sensor_ax',
    'Sensor.SENSOR_AX_223',
    description: 'Longitudinal acceleration sensor (Ax)',
  ),
  _Sig(
    'sensor_ay',
    'Sensor.SENSOR_AY_223',
    description: 'Lateral acceleration sensor (Ay)',
  ),

  // ── ADAS (expansion) ──────────────────────────────────────────
  _Sig(
    'adas_acc_mode',
    'Adas.ADAS_ACC_MODE',
    description: 'Adaptive cruise control mode',
  ),
  _Sig(
    'adas_acc_text',
    'Adas.ADAS_ACC_TEXT_INFO_FOR_DRIVER',
    description: 'ACC driver text info code',
  ),
  _Sig(
    'adas_aeb_active',
    'Adas.ADAS_AEB_ACTIVE',
    description: 'AEB (autonomous emergency braking) active state',
  ),
  _Sig(
    'adas_aeb_state',
    'Adas.ADAS_AEB_STATE',
    description: 'AEB system state',
  ),
  _Sig('adas_aeb_error', 'Adas.ADAS_AEB_ERROR', description: 'AEB error code'),
  _Sig(
    'adas_abs_active',
    'Adas.ADAS_ABS_ACTIVE',
    description: 'ABS (anti-lock braking) active',
  ),
  _Sig(
    'adas_avh_alt',
    'Adas.ADAS_AVH_STATE',
    description: 'AVH state (alias of avh_state)',
  ),
  _Sig(
    'adas_fcw_state',
    'Adas.ADAS_FCW_LEVEL_STATUS',
    description: 'Forward collision warning level status',
  ),
  _Sig('adas_fcw_error', 'Adas.ADAS_FCW_ERROR', description: 'FCW error code'),
  _Sig(
    'adas_fcw_config',
    'Adas.ADAS_FCW_CONFIG',
    description: 'FCW configuration / sensitivity',
  ),
  _Sig(
    'adas_bsd_state',
    'Adas.ADAS_BSD_STATE',
    description: 'Blind-spot detection state',
  ),
  _Sig(
    'adas_bsd_cfg',
    'Adas.ADAS_BSD_CONFIG',
    description: 'BSD sensitivity / configuration',
  ),
  _Sig(
    'adas_bsd_fl',
    'Adas.ADAS_FL_BLIND_SPOT_ALARM_ACTIVE_SIGNAL_STATUS',
    description: 'Front-left blind-spot alarm active',
  ),
  _Sig(
    'adas_bsd_fr',
    'Adas.ADAS_FR_BLIND_SPOT_ALARM_ACTIVE_SIGNAL_STATUS',
    description: 'Front-right blind-spot alarm active',
  ),
  _Sig(
    'adas_elka_state',
    'Adas.ADAS_ELKA_SWITCH_STATE',
    description: 'Emergency lane-keep assist switch state',
  ),
  _Sig(
    'adas_elka_cfg',
    'Adas.ADAS_ELKA_CONFIG',
    description: 'Emergency lane-keep assist configuration',
  ),
  _Sig(
    'adas_lka_value_state',
    'Adas.ADAS_LKA_CONTROL_DELIVERED_VALUE_STATE',
    description: 'LKA control delivered value state',
  ),
  _Sig(
    'adas_eps_lka_state',
    'Adas.ADAS_EPS_LKA_CONTROL_STATE',
    description: 'EPS LKA control state',
  ),
  _Sig(
    'adas_apa_state',
    'Adas.ADAS_APA_AUTOMATIC_PARKING_STATUS',
    description: 'Auto Parking Assist (APA) status',
  ),
  _Sig(
    'adas_apa_front_state',
    'Adas.ADAS_APA_FRONT_PARK_STATE',
    description: 'APA front-parking state',
  ),
  _Sig(
    'adas_apa_park_mode',
    'Adas.ADAS_APA_PARK_MODE_STATUS',
    description: 'APA park-mode status',
  ),
  _Sig(
    'adas_apa_park_duration',
    'Adas.ADAS_APA_PARK_DURATION',
    description: 'APA park duration',
    units: 'seconds',
  ),
  _Sig(
    'adas_apa_abort_reason',
    'Adas.ADAS_APA_ABORT_REASON',
    description: 'APA abort reason code',
  ),
  _Sig(
    'adas_apa_pause_avail',
    'Adas.ADAS_APA_PAUSE_BUTTON_AVAILABILITY',
    description: 'APA pause button available',
  ),
  _Sig(
    'adas_apa_resume_avail',
    'Adas.ADAS_APA_RESUME_BUTTON_AVAILABILITY',
    description: 'APA resume button available',
  ),
  _Sig(
    'adas_apa_parkin_avail',
    'Adas.ADAS_APA_PARKIN_START_BUTTON_AVAILABILITY',
    description: 'APA park-in start button available',
  ),
  _Sig(
    'adas_apa_parkout_avail',
    'Adas.ADAS_APA_PARKOUT_START_BUTTON_AVAILABILITY',
    description: 'APA park-out start button available',
  ),
  _Sig(
    'adas_apa_parkout_left',
    'Adas.ADAS_APA_PARKOUT_TOLEFT',
    description: 'APA park-out left direction available',
  ),
  _Sig(
    'adas_apa_parkout_right',
    'Adas.ADAS_APA_PARKOUT_TORIGHT',
    description: 'APA park-out right direction available',
  ),
  _Sig(
    'adas_apa_parkout_fwd',
    'Adas.ADAS_APA_PARKOUT_FORWARD',
    description: 'APA park-out forward direction available',
  ),
  _Sig(
    'adas_apa_parkout_bwd',
    'Adas.ADAS_APA_PARKOUT_BACKWARD',
    description: 'APA park-out backward direction available',
  ),
  _Sig(
    'adas_apa_space_beep',
    'Adas.ADAS_APA_PARKING_SPACE_BEEP',
    description: 'APA parking space beep enable',
  ),
  _Sig(
    'adas_apa_search_paused_reason',
    'Adas.ADAS_APA_SEARCH_SUSPENDED_REASON',
    description: 'APA search suspended reason',
  ),
  _Sig(
    'adas_avp_state',
    'Adas.ADAS_AVP_PARKIN_STATUS',
    description: 'Autonomous valet parking (AVP) park-in status',
  ),
  _Sig(
    'adas_avp_parkin_avail',
    'Adas.ADAS_AVP_PARKIN_BUTTON_AVAILABLE_STATUS',
    description: 'AVP park-in button available',
  ),
  _Sig(
    'adas_avp_start_avail',
    'Adas.ADAS_AVP_START_PARKIN_BUTTON_STATUS',
    description: 'AVP start-parkin button status',
  ),
  _Sig(
    'adas_avp_map_build_avail',
    'Adas.ADAS_AVP_BUILD_PARKIN_MAP_AVAILABLE_STATUS',
    description: 'AVP map-build availability status',
  ),
  _Sig(
    'adas_avp_inout_mode',
    'Adas.ADAS_AVP_PARKIN_OUT_STATUS_MODE',
    description: 'AVP parkin / parkout mode',
  ),
  _Sig(
    'adas_avp_map_request',
    'Adas.ADAS_AVP_MAP_AND_PARK_REQUEST_MODE',
    description: 'AVP map-and-park request mode',
  ),
  _Sig(
    'adas_actual_speed',
    'Adas.ADAS_ACTUAL_EXECUTION_SPEED',
    description: 'ADAS actual execution speed',
    units: 'km/h',
  ),
  _Sig(
    'adas_front_vehicle_speed',
    'Adas.ADAS_FRONT_VEHICLE_SPEED',
    description: 'Front-vehicle measured speed',
    units: 'km/h',
  ),
  _Sig(
    'adas_front_vehicle_dist',
    'Adas.ADAS_FRONT_VEHICLE_DISTANCE',
    description: 'Front-vehicle measured distance',
  ),
  _Sig(
    'adas_front_vehicle_accel',
    'Adas.ADAS_FRONT_VEHICLE_ACCELERATION',
    description: 'Front-vehicle measured acceleration',
  ),
  _Sig(
    'adas_front_vehicle_state',
    'Adas.ADAS_FRONT_VEHICLE_STATUS',
    description: 'Front-vehicle status (stopped / moving / no target)',
  ),
  _Sig(
    'adas_front_start_remind',
    'Adas.ADAS_FRONT_CAR_START_REMINDER_SWITCH_STATUS',
    description: 'Front-car start-reminder switch',
  ),
  _Sig(
    'adas_traffic_green_start',
    'Adas.ADAS_FRONT_VEHICLE_START_REMINDER_AND_TRAFFIC_LIGHT_GREEN_START_REMINDER',
    description: 'Traffic-light green / front-car start reminder',
  ),
  _Sig(
    'adas_aim_speed_offset',
    'Adas.ADAS_AIM_SPEED_OFFSET',
    description: 'ADAS target speed offset',
    units: 'km/h',
  ),
  _Sig(
    'adas_aim_speed_offset_pct',
    'Adas.ADAS_AIM_SPEED_OFFSET_PERCENTAGE',
    description: 'ADAS target speed offset percentage',
    units: 'percent',
  ),
  _Sig(
    'adas_aim_speed_offset_mode',
    'Adas.ADAS_AIM_SPEED_OFFSET_MODE',
    description: 'ADAS target speed offset mode (absolute / percent)',
  ),
  _Sig(
    'adas_sla_speed',
    'Adas.ADAS_SLA_OUTPUT_SPEED_LIMIT',
    description: 'Speed-limit-assist output speed limit',
    units: 'km/h',
  ),
  _Sig(
    'adas_slr_speed',
    'Adas.ADAS_SLR_OUTPUT_SEPPD_LIMIT',
    description: 'Speed-limit recognition output speed limit',
    units: 'km/h',
  ),
  _Sig(
    'adas_smart_speed_limit',
    'Adas.ADAS_SMART_SPEED_LIMIT_CONTROL',
    description: 'Smart speed-limit control state',
  ),
  _Sig(
    'adas_speed_limit_assist_kph',
    'Adas.ADAS_SPEED_LIMIT_ASSIST_OFFSET_KPH',
    description: 'Speed-limit assist offset in km/h',
    units: 'km/h',
  ),
  _Sig(
    'adas_speed_limit_assist_mph',
    'Adas.ADAS_SPEED_LIMIT_ASSIST_OFFSET_MPH',
    description: 'Speed-limit assist offset in mph',
  ),
  _Sig(
    'adas_traffic_limit_status',
    'Adas.ADAS_TRAFFIC_LIMIT_SPEED_STATUS_PROMPT',
    description: 'Traffic speed-limit prompt status',
  ),
  _Sig(
    'adas_speed_limit_sign',
    'Adas.ADAS_SPEED_LIMIT_SURVEILLANCE_SIGN',
    description: 'Speed-limit surveillance sign id',
  ),
  _Sig(
    'adas_high_limit_warn',
    'Adas.ADAS_HIGH_ATTACHED_SPEED_LIMIT_WARNING_SIGN',
    description: 'High-speed-limit warning sign',
  ),
  _Sig(
    'adas_lcc_state',
    'Adas.ADAS_LCC_NCA_FUNCTION_STATUS',
    description: 'Lane-cruise / NCA function status',
  ),
  _Sig(
    'adas_assist_drive_state',
    'Adas.ADAS_ASSIST_DRIVE_MODE_STATUS',
    description: 'Driver-assist mode status',
  ),
  _Sig(
    'adas_anti_motion_switch',
    'Adas.ADAS_ANTIMOTION_CONTROL_SWITCH_SIGNAL',
    description: 'Anti-motion-sickness control switch',
  ),
  _Sig(
    'adas_anti_motion_cfg',
    'Adas.ADAS_ANTIMOTION_CONTROL_SWITCH_CONFIG',
    description: 'Anti-motion-sickness config',
  ),
  _Sig(
    'adas_anti_motion_fail',
    'Adas.ADAS_ANTIMOTION_FUNCTION_FAILURE_STATUS',
    description: 'Anti-motion-sickness failure status',
  ),
  _Sig(
    'adas_driver_grip_status',
    'Adas.ADAS_DRIVER_GRIP_STATUS',
    description: 'Driver hand-on-wheel grip status',
  ),
  _Sig(
    'adas_driver_grip_area',
    'Adas.ADAS_DRIVER_GRIP_AREA',
    description: 'Driver grip area on wheel',
  ),
  _Sig(
    'adas_driver_intervene',
    'Adas.ADAS_DRIVER_STEERING_WHEEL_INTERVENTION_PROMPT',
    description: 'Driver-intervention prompt',
  ),
  _Sig(
    'adas_driver_takeover',
    'Adas.ADAS_DRIVER_TAKEOVER_REQUEST_1',
    description: 'Driver takeover request',
  ),
  _Sig(
    'adas_alarm_status',
    'Adas.ADAS_ALARM_STATUS',
    description: 'ADAS alarm status code',
  ),
  _Sig(
    'adas_warn_acute',
    'Adas.ADAS_ACUTE_WARNING_STATE',
    description: 'Acute (urgent) warning state',
  ),
  _Sig(
    'adas_emergency_brake_warn',
    'Adas.ADAS_EMERGENCY_BRAKING_WARNING_OUTPUT',
    description: 'Emergency braking warning output',
  ),
  _Sig(
    'adas_emergency_brake_dist',
    'Adas.ADAS_EMERGENCY_BRAKING_DISTANCE_WARNING_OUTPUT',
    description: 'Emergency braking distance warning',
  ),
  _Sig(
    'adas_emergency_vehicle_warn',
    'Adas.ADAS_EMERGENCY_VEHICLE_WARNING_OUTPUT',
    description: 'Emergency vehicle (siren) warning',
  ),
  _Sig(
    'adas_emergency_vehicle_type',
    'Adas.ADAS_EMERGENCY_VEHICLE_TYPE_OUTPUT',
    description: 'Emergency vehicle type',
  ),
  _Sig(
    'adas_abnormal_vehicle_warn',
    'Adas.ADAS_ABNORMAL_VEHICLE_WARNING_OUTPUT',
    description: 'Abnormal-vehicle warning output',
  ),
  _Sig(
    'adas_height_limit_warn',
    'Adas.ADAS_HEIGHT_LIMIT_ATTENTION_STATUS',
    description: 'Height-limit warning status',
  ),
  _Sig(
    'adas_height_limit_cfg',
    'Adas.ADAS_HEIGHT_LIMIT_ATTENTION_CONFIG',
    description: 'Height-limit configuration',
  ),
  _Sig(
    'adas_alarm_prompt',
    'Adas.ADAS_ALN_ALARM_INFO_PROMPT',
    description: 'ADAS alarm info prompt',
  ),
  _Sig(
    'adas_front_radar_fctb',
    'Adas.ADAS_FRONT_RADAR_FCTB_ALARM_SIGNAL',
    description: 'Front-radar cross-traffic brake alarm',
  ),
  _Sig(
    'adas_front_parking_support',
    'Adas.ADAS_FRONT_PARKING_SUPPORT',
    description: 'Front parking-sensor support flag',
  ),
  _Sig(
    'adas_park_space_func',
    'Adas.ADAS_COMPREHENSIVE_OPTIONAL_PARKING_SPACE_FUNCTION',
    description: 'Comprehensive parking-space option',
  ),
  _Sig(
    'adas_lane_signal_phase',
    'Adas.ADAS_CURRENT_LANE_SIGNAL_PHASE_OUTPUT',
    description: 'Current lane traffic-light phase',
  ),
  _Sig(
    'adas_lane_signal_time',
    'Adas.ADAS_CURRENT_LANE_SIGNAL_TIME_OUTPUT',
    description: 'Current lane traffic-light time remaining',
    units: 'seconds',
  ),
  _Sig(
    'adas_green_wave_suggest',
    'Adas.ADAS_GREEN_WAVE_SPEED_GUIDE_SUGGEST_SPEED_OUTPUT',
    description: 'Green-wave suggested speed',
    units: 'km/h',
  ),
  _Sig(
    'adas_adb_detection',
    'Adas.ADAS_ADB_DETECTION_SYSTEM_STATUS',
    description: 'ADB (adaptive driving beam) detection system status',
  ),
  _Sig(
    'adas_ads_alarm_attention',
    'Adas.ADAS_ADS_ALARM_SOUND_ATTENTION',
    description: 'ADS alarm-sound attention level',
  ),
  _Sig(
    'adas_ads_tjp',
    'Adas.ADAS_ADS_TJP_STATUS',
    description: 'ADS traffic-jam-pilot status',
  ),
  _Sig(
    'adas_ads_platform',
    'Adas.ADAS_ADS_PLATFORM_TYPE',
    description: 'ADS platform type code',
  ),
  _Sig(
    'adas_4g_signal',
    'Adas.ADAS_4G_SIGNAL_STRENGTH',
    description: '4G signal strength (ADAS comms)',
  ),
  _Sig(
    'adas_belt_cruise_monitor',
    'Adas.ADAS_CRUISE_STATE_SEATBELT_MONITOR_SIGNAL',
    description: 'Cruise state seatbelt monitor signal',
  ),
  _Sig(
    'adas_cruise_one_key',
    'Adas.ADAS_CRUISE_ONE_KEY_ACTIVE_STATUS',
    description: 'Cruise one-key active status',
  ),
  _Sig(
    'adas_cruise_tow_cfg',
    'Adas.ADAS_CRUISE_CTR_ON_TOW_CONFIG',
    description: 'Cruise-on-tow configuration',
  ),
  _Sig(
    'adas_aeb_seatbelt',
    'Adas.ADAS_AEB_SEATBELT_MEMORY_SWITCH_STATUS',
    description: 'AEB-seatbelt memory switch status',
  ),
  _Sig(
    'adas_aes_status',
    'Adas.ADAS_AES_FUNC_STATUS_SIGNAL',
    description: 'Auto emergency steering function status',
  ),
  _Sig(
    'adas_aes_feedback',
    'Adas.ADAS_AES_FUNC_SWITCH_FEEDBACK',
    description: 'AES function-switch feedback',
  ),
  _Sig(
    'adas_lka_value',
    'Adas.ADAS_LKA_CTRL_1D1_VALUE_STATE',
    description: 'LKA control raw value state',
  ),
  _Sig(
    'adas_asa_state',
    'Adas.ADAS_ASA_CONTROL_STATUS',
    description: 'Active speed adjust (ASA) control status',
  ),
  _Sig(
    'adas_dms_sos',
    'Adas.ADAS_DMS_MONITOR_DRIVER_DISABILITY_SCENARIO_SOS',
    description: 'DMS driver-disability SOS trigger',
  ),
  _Sig(
    'adas_turn_signal_request',
    'Adas.ADAS_DOMAIN_CONTROL_TURN_SIGNAL_REQUEST',
    description: 'Domain-control turn-signal request',
  ),
  _Sig(
    'adas_actual_lr_steer',
    'Adas.ADAS_ACTUAL_LEFT_REAR_WHEEL_STEERING_ANGLE',
    description: 'Actual left-rear wheel steering angle',
  ),
  _Sig(
    'adas_actual_rr_steer',
    'Adas.ADAS_ACTUAL_RIGHT_REAR_WHEEL_STEERING_ANGLE',
    description: 'Actual right-rear wheel steering angle',
  ),
  _Sig(
    'adas_actual_rear_steer_valid',
    'Adas.ADAS_ACTUAL_REAR_WHEEL_STEERING_ANGLE_VALIDITY',
    description: 'Rear-steer angle validity flag',
  ),
  _Sig(
    'adas_drvr_paddle_l',
    'Adas.ADAS_ADVANCED_DRIVNG_FUNC_LEFT_PADDLE_STATUS',
    description: 'Advanced-drive left paddle status',
  ),
  _Sig(
    'adas_drvr_paddle_r',
    'Adas.ADAS_ADVANCED_DRIVNG_FUNC_RIGHT_PADDLE_STATUS',
    description: 'Advanced-drive right paddle status',
  ),
  _Sig(
    'adas_amap_gray',
    'Adas.ADAS_AMAP_GRAY_STATUS',
    description: 'AMAP gray-out availability status',
  ),
  _Sig(
    'adas_avc_support',
    'Adas.ADAS_AVC_SUPPORT',
    description: 'AVC (auto-vehicle-control) supported',
  ),
  _Sig(
    'adas_aes_gray',
    'Adas.ADAS_AES_FUNC_MODE_GRAYED_OUT_SIGNAL',
    description: 'AES grayed-out signal',
  ),
  _Sig(
    'adas_acc_gray',
    'Adas.ADAS_ACC_GRAY_STATE',
    description: 'ACC grayed-out state',
  ),
  _Sig(
    'adas_aeb_gray',
    'Adas.ADAS_AUTONOMOUS_EMERGENCY_BRAKING_GRAY',
    description: 'AEB grayed-out state',
  ),
  _Sig(
    'adas_aeb_seatbelt_gray',
    'Adas.ADAS_AEB_SEATBELT_GRAYED_OUT',
    description: 'AEB-seatbelt grayed-out state',
  ),
  _Sig(
    'adas_autopark_1',
    'Adas.ADAS_AUTOPARK_FIRST_PARKING_SPACE_STATUS',
    description: 'Auto-park first space status',
  ),
  _Sig(
    'adas_autopark_2',
    'Adas.ADAS_AUTOPARK_SECOND_PARKING_SPACE_STATUS',
    description: 'Auto-park second space status',
  ),
  _Sig(
    'adas_autopark_3',
    'Adas.ADAS_AUTOPARK_THIRD_PARKING_SPACE_STATUS',
    description: 'Auto-park third space status',
  ),
  _Sig(
    'adas_autopark_4',
    'Adas.ADAS_AUTOPARK_FOURTH_PARKING_SPACE_STATUS',
    description: 'Auto-park fourth space status',
  ),
  _Sig(
    'adas_autopark_5',
    'Adas.ADAS_AUTOPARK_FIFTH_PARKING_SPACE_STATUS',
    description: 'Auto-park fifth space status',
  ),
  _Sig(
    'adas_autopark_6',
    'Adas.ADAS_AUTOPARK_SIXTH_PARKING_SPACE_STATUS',
    description: 'Auto-park sixth space status',
  ),
  _Sig(
    'adas_3rd_row_belt_warn',
    'Adas.ADAS_CENTER_REAR_THIRD_ROW_SEATBELT_UNBUCKLED_WARNING_STATUS',
    description: '3rd-row centre seatbelt unbuckled warning',
  ),
  _Sig(
    'adas_anti_dazzle',
    'Adas.ADAS_ANTI_DAZZLE_FLOATING_POINT_0X0D3',
    description: 'Anti-dazzle (HBA) floating-point state',
  ),
  _Sig(
    'adas_cbw_obstacle_1',
    'Adas.ADAS_CBW_FIRST_OBSTACLE_HEIGHT_GRADE',
    description: 'CBW first-obstacle height grade',
  ),
  _Sig(
    'adas_cbw_obstacle_2',
    'Adas.ADAS_CBW_SECOND_OBSTACLE_HEIGHT_GRADE',
    description: 'CBW second-obstacle height grade',
  ),
  _Sig(
    'adas_cbw_obstacle_3',
    'Adas.ADAS_CBW_THIRD_OBSTACLE_HEIGHT_GRADE',
    description: 'CBW third-obstacle height grade',
  ),
  _Sig(
    'adas_e4_exit_dir',
    'Adas.ADAS_E4_PARKING_EXIT_DIRECTION',
    description: 'E4 parking exit direction',
  ),
  _Sig(
    'adas_e4_space_type',
    'Adas.ADAS_E4_PARKING_SPACE_TYPE',
    description: 'E4 parking space type',
  ),
  _Sig(
    'adas_acc_arhud',
    'Adas.ADAS_ACC_MODE_ARHUD',
    description: 'ACC mode displayed on AR-HUD',
  ),

  // ── Instrument cluster (expansion) ────────────────────────────
  _Sig(
    'inst_dd_speed_unit',
    'Instrument.INSTRUMENT_DD_SPEED_UNIT',
    description: 'Driver-display speed unit (0 km/h, 1 mph)',
    category: 'system',
  ),
  _Sig(
    'inst_dd_mileage_unit',
    'Instrument.INSTRUMENT_DD_MILEAGE_UNIT',
    description: 'Driver-display mileage unit (0 km, 1 mi)',
    category: 'system',
  ),
  _Sig(
    'inst_dd_power_unit',
    'Instrument.INSTRUMENT_DD_POWER_UNIT',
    description: 'Driver-display power unit',
    category: 'system',
  ),
  _Sig(
    'inst_dd_acc_speed',
    'Instrument.INSTRUMENT_DD_ACC_SPEED',
    description: 'ACC current speed (driver display)',
    units: 'km/h',
    category: 'dynamics',
  ),
  _Sig(
    'inst_dd_acc_cruising_speed',
    'Instrument.INSTRUMENT_DD_ACC_CRUISING_SPEED',
    description: 'ACC cruising set speed (driver display)',
    units: 'km/h',
    category: 'dynamics',
  ),
  _Sig(
    'inst_dd_acc_indicator',
    'Instrument.INSTRUMENT_DD_ACC_INDICAT_LIGHT_STATE',
    description: 'ACC indicator lamp state',
    category: 'system',
  ),
  _Sig(
    'inst_dd_main_belt',
    'Instrument.INSTRUMENT_DD_MAIN_DRIVER_SAFETYBELT_STATE',
    description: 'Cluster driver seatbelt state',
    category: 'safety',
  ),
  _Sig(
    'inst_dd_deputy_belt',
    'Instrument.INSTRUMENT_DD_DEPUTY_SAFETYBELT_STATE',
    description: 'Cluster passenger seatbelt state',
    category: 'safety',
  ),
  _Sig(
    'inst_dd_rear_l_belt',
    'Instrument.INSTRUMENT_DD_REAR_LEFT_SAFETYBELT_STATE',
    description: 'Cluster rear-left seatbelt state',
    category: 'safety',
  ),
  _Sig(
    'inst_dd_rear_mid_belt',
    'Instrument.INSTRUMENT_DD_REAR_MID_SAFETYBELT_STATE',
    description: 'Cluster rear-centre seatbelt state',
    category: 'safety',
  ),
  _Sig(
    'inst_dd_rear_r_belt',
    'Instrument.INSTRUMENT_DD_REAR_RIGHT_SAFETYBELT_STATE',
    description: 'Cluster rear-right seatbelt state',
    category: 'safety',
  ),
  _Sig(
    'inst_dd_lf_door',
    'Instrument.INSTRUMENT_DD_LEFT_FRONT_DOOR_STATE',
    description: 'Cluster front-left door state',
    category: 'doors',
  ),
  _Sig(
    'inst_dd_rf_door',
    'Instrument.INSTRUMENT_DD_RIGHT_FRONT_DOOR_STATE',
    description: 'Cluster front-right door state',
    category: 'doors',
  ),
  _Sig(
    'inst_dd_lr_door',
    'Instrument.INSTRUMENT_DD_LEFT_REAR_DOOR_STATE',
    description: 'Cluster rear-left door state',
    category: 'doors',
  ),
  _Sig(
    'inst_dd_rr_door',
    'Instrument.INSTRUMENT_DD_RIGHT_REAR_DOOR_STATE',
    description: 'Cluster rear-right door state',
    category: 'doors',
  ),
  _Sig(
    'inst_dd_trunk',
    'Instrument.INSTRUMENT_DD_LUGGAGE_DOOR_STATE',
    description: 'Cluster trunk state',
    category: 'doors',
  ),
  _Sig(
    'inst_dd_hood',
    'Instrument.INSTRUMENT_DD_HOOD_STATE',
    description: 'Cluster hood state',
    category: 'doors',
  ),
  _Sig(
    'inst_dd_oil_lamp',
    'Instrument.INSTRUMENT_DD_OIL_LEVEL_LIGHT',
    description: 'Cluster low-oil-level warning lamp',
    category: 'safety',
  ),
  _Sig(
    'inst_dd_ext_chg_power',
    'Instrument.INSTRUMENT_DD_EXTERNAL_CHARGE_POWER',
    description: 'Cluster external charge power',
    units: 'kw',
    category: 'charging',
  ),
  _Sig(
    'inst_dd_energy_intensity',
    'Instrument.INSTRUMENT_DD_ENERGY_INTENSITY_FEEDBACK',
    description: 'Cluster energy intensity feedback',
    category: 'propulsion',
  ),
  _Sig(
    'inst_dd_lane_state',
    'Instrument.INSTRUMENT_DD_LANE_LINE_STATE',
    description: 'Cluster lane-line state',
    category: 'adas',
  ),
  _Sig(
    'inst_dd_deviation',
    'Instrument.INSTRUMENT_DD_DEVIATION_STATE',
    description: 'Cluster lane-deviation state',
    category: 'adas',
  ),
  _Sig(
    'inst_dd_gap_detect',
    'Instrument.INSTRUMENT_DD_GAP_DETECTION',
    description: 'Cluster ACC gap-detection state',
    category: 'adas',
  ),
  _Sig(
    'inst_dd_spacing',
    'Instrument.INSTRUMENT_DD_SPACING_STATE',
    description: 'Cluster spacing/distance state',
    category: 'adas',
  ),
  _Sig(
    'inst_dd_time_interval',
    'Instrument.INSTRUMENT_DD_TIME_INTERVAL_STATE',
    description: 'Cluster time-interval state',
    category: 'adas',
  ),
  _Sig(
    'inst_dd_pcw_alarm',
    'Instrument.INSTRUMENT_DD_PCW_SAFE_DIST_ALARM_INSTRUCTION',
    description: 'Pedestrian/collision-warning alarm instruction',
    category: 'safety',
  ),
  _Sig(
    'inst_dd_tpms_lf',
    'Instrument.INSTRUMENT_DD_INDIRECT_TYPE_PRES_LF',
    description: 'Cluster indirect-TPMS front-left',
    category: 'safety',
  ),
  _Sig(
    'inst_dd_tpms_rf',
    'Instrument.INSTRUMENT_DD_INDIRECT_TYPE_PRES_RF',
    description: 'Cluster indirect-TPMS front-right',
    category: 'safety',
  ),
  _Sig(
    'inst_dd_tpms_lr',
    'Instrument.INSTRUMENT_DD_INDIRECT_TYPE_PRES_LR',
    description: 'Cluster indirect-TPMS rear-left',
    category: 'safety',
  ),
  _Sig(
    'inst_dd_tpms_rr',
    'Instrument.INSTRUMENT_DD_INDIRECT_TYPE_PRES_RR',
    description: 'Cluster indirect-TPMS rear-right',
    category: 'safety',
  ),
  _Sig(
    'inst_dd_50km_power',
    'Instrument.INSTRUMENT_DD_LAST_50KM_POWER_CONSUME',
    description: 'Cluster last-50km power consumption',
    category: 'statistics',
  ),
  _Sig(
    'inst_dd_sound_type',
    'Instrument.INSTRUMENT_DD_SOUND_TYPE',
    description: 'Cluster sound type',
    category: 'media',
  ),
  _Sig(
    'inst_dd_sound_freq',
    'Instrument.INSTRUMENT_DD_SOUND_FREQ',
    description: 'Cluster sound frequency',
    category: 'media',
  ),
  _Sig(
    'inst_dd_air_heating_oil',
    'Instrument.INSTRUMENT_DD_AIR_HEATING_OIL_DISPLAY',
    description: 'Cluster fuel air-heating display',
    category: 'climate',
  ),
  _Sig(
    'inst_charging_socket',
    'Instrument.INSTRUMENT_CHARGING_SOCKET',
    description: 'Charging socket cluster indicator',
    category: 'charging',
  ),
  _Sig(
    'inst_smart_key_warn',
    'Instrument.INSTRUMENT_SMART_KEY_SYS_WARN_LIGHT',
    description: 'Smart-key system warn light',
    category: 'safety',
  ),
  _Sig(
    'inst_brightness',
    'Instrument.INSTRUMENT_BRIGHTNESS_GEAR_FEEDBACK_STATUS',
    description: 'Cluster brightness gear feedback',
    category: 'system',
    units: 'percent',
    range: IntRange(0, 100),
  ),
  _Sig(
    'inst_brightness_awning',
    'Instrument.INSTRUMENT_ADJUST_BRIGHTNESS_AWNING_ADJUST_GEAR',
    description: 'Cluster awning brightness gear',
    category: 'system',
  ),
  _Sig(
    'inst_ok_indicator',
    'Instrument.INSTRUMENT_OK_INDICATOR',
    description: 'Generic OK indicator',
    category: 'safety',
  ),
  _Sig(
    'inst_p_gear_lock',
    'Instrument.INSTRUMENT_P_GEAR_LOCK_FAILURE_INDICATOR',
    description: 'P-gear lock-failure indicator',
    category: 'safety',
  ),
  _Sig(
    'inst_energy_indicator',
    'Instrument.INSTRUMENT_ENERGY_SYSTEM_INDICATOR',
    description: 'Energy-system indicator',
    category: 'propulsion',
  ),
  _Sig(
    'inst_eps_indicator',
    'Instrument.INSTRUMENT_EPS_INDICATOR',
    description: 'EPS (electric power steering) indicator',
    category: 'safety',
  ),
  _Sig(
    'inst_esc_indicator',
    'Instrument.INSTRUMENT_ESC_INDICATOR',
    description: 'ESC indicator',
    category: 'safety',
  ),
  _Sig(
    'inst_svs_indicator',
    'Instrument.INSTRUMENT_SVS_INDICATOR',
    description: 'Service vehicle soon (SVS) indicator',
    category: 'safety',
  ),
  _Sig(
    'inst_tsr_indicator',
    'Instrument.INSTRUMENT_FUZZ_TRAFFIC_SIGN_RECOGNITION_INDICATOR',
    description: 'Traffic-sign recognition indicator',
    category: 'adas',
  ),
  _Sig(
    'inst_steering_system',
    'Instrument.INSTRUMENT_STEERING_SYSTEM',
    description: 'Steering system cluster indicator',
    category: 'safety',
  ),
  _Sig(
    'inst_bm_steering',
    'Instrument.INSTRUMENT_B_M_STEERING_SYSTEM',
    description: 'B/M steering system status',
    category: 'safety',
  ),
  _Sig(
    'inst_bm_gear',
    'Instrument.INSTRUMENT_B_M_GEAR_SYSTEM',
    description: 'B/M gear system status',
    category: 'propulsion',
  ),
  _Sig(
    'inst_bm_lv_power',
    'Instrument.INSTRUMENT_B_M_LOW_VOLTAGE_POWER_SUPPLY_SYSTEM',
    description: 'Low-voltage power supply system status',
    category: 'system',
  ),
  _Sig(
    'inst_fault_abs',
    'Instrument.INSTRUMENT_2IN1_FAULT_ABS_FAILURE_WARN_LIGHT',
    description: 'ABS failure warning light',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_brake_sys',
    'Instrument.INSTRUMENT_2IN1_FAULT_BRAKE_SYS_FAILURE_WARN_LIGHT',
    description: 'Brake system failure warning light',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_engine',
    'Instrument.INSTRUMENT_2IN1_FAULT_ENGINE_FAILURE_WARN_LIGHT',
    description: 'Engine failure warning light',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_esp',
    'Instrument.INSTRUMENT_2IN1_FAULT_ESP_FAILURE_WARN_LIGHT',
    description: 'ESP failure warning light',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_low_fuel',
    'Instrument.INSTRUMENT_2IN1_FAULT_LOW_FUEL_WARN_LIGHT',
    description: 'Low-fuel warning light',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_low_oil_press',
    'Instrument.INSTRUMENT_2IN1_FAULT_LOW_OIL_PRESSURE_WARN_LIGHT',
    description: 'Low oil pressure warning',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_low_battery',
    'Instrument.INSTRUMENT_2IN1_FAULT_LOW_POWER_BATTERY_WARN_LIGHT',
    description: 'Low low-voltage battery warning',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_hv_battery',
    'Instrument.INSTRUMENT_2IN1_FAULT_POWER_BAT_FAILURE_WARN_LIGHT',
    description: 'HV battery failure warning',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_hv_battery_heat',
    'Instrument.INSTRUMENT_2IN1_FAULT_POWER_BATTERY_HEAT_WARN_LIGHT',
    description: 'HV battery overheat warning',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_power_sys',
    'Instrument.INSTRUMENT_2IN1_FAULT_POWER_SYS_FAILURE_WARN_LIGHT',
    description: 'HV power-system failure warning',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_steering',
    'Instrument.INSTRUMENT_2IN1_FAULT_STEERING_SYS_FAILURE_WARN_LIGHT',
    description: 'Steering system failure warning',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_srs',
    'Instrument.INSTRUMENT_2IN1_FAULT_SRS_FAILURE_WARN_LIGHT',
    description: 'SRS (airbag) failure warning',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_tpms',
    'Instrument.INSTRUMENT_2IN1_FAULT_TYRE_PRESSURE_SYS_FAILURE_WARN_LIGHT',
    description: 'TPMS failure warning',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_coolant',
    'Instrument.INSTRUMENT_2IN1_FAULT_COOLANT_TEMP_HIGH_WARN_LIGHT',
    description: 'Coolant high-temp warning',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_smart_key',
    'Instrument.INSTRUMENT_2IN1_FAULT_SMART_KEY_SYS_WARN_LIGHT',
    description: 'Smart-key system warning',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_pressure_supply',
    'Instrument.INSTRUMENT_2IN1_FAULT_PRESSURE_SUPPLY_SYS_FAILURE_WARN_LIGHT',
    description: 'Pressure-supply system failure',
    category: 'safety',
  ),
  _Sig(
    'inst_fault_headlamp',
    'Instrument.INSTRUMENT_2IN1_HEADLAMP_FAILURE_WARN_LIGHT',
    description: 'Headlamp failure warning',
    category: 'safety',
  ),
  _Sig(
    'inst_ev_indicator',
    'Instrument.INSTRUMENT_2IN1_FAULT_EV_INDICATOR',
    description: 'EV mode indicator (cluster)',
    category: 'propulsion',
  ),
  _Sig(
    'inst_hev_indicator',
    'Instrument.INSTRUMENT_2IN1_FAULT_HEV_INDICATOR',
    description: 'HEV mode indicator (cluster)',
    category: 'propulsion',
  ),
  _Sig(
    'inst_eco_indicator',
    'Instrument.INSTRUMENT_2IN1_FAULT_ECO_INDICATOR',
    description: 'ECO mode indicator',
    category: 'propulsion',
  ),
  _Sig(
    'inst_sport_indicator',
    'Instrument.INSTRUMENT_2IN1_FAULT_SPORT_INDICATOR',
    description: 'Sport mode indicator',
    category: 'propulsion',
  ),
  _Sig(
    'inst_normal_indicator',
    'Instrument.INSTRUMENT_2IN1_FAULT_NORMAL_INDICATOR',
    description: 'Normal mode indicator',
    category: 'propulsion',
  ),
  _Sig(
    'inst_sand_indicator',
    'Instrument.INSTRUMENT_2IN1_FAULT_SAND_INDICATOR',
    description: 'Sand-mode indicator',
    category: 'propulsion',
  ),
  _Sig(
    'inst_muddy_indicator',
    'Instrument.INSTRUMENT_2IN1_FAULT_MUDDY_INDICATOR',
    description: 'Muddy-mode indicator',
    category: 'propulsion',
  ),
  _Sig(
    'inst_grass_indicator',
    'Instrument.INSTRUMENT_2IN1_FAULT_GRASS_INDICATOR',
    description: 'Grass-mode indicator',
    category: 'propulsion',
  ),
  _Sig(
    'inst_cruise_ctrl_ind',
    'Instrument.INSTRUMENT_2IN1_FAULT_CRUISE_CTRL_INDICATOR',
    description: 'Cruise-control indicator',
    category: 'dynamics',
  ),
  _Sig(
    'inst_cruise_main_ind',
    'Instrument.INSTRUMENT_2IN1_FAULT_CRUISE_MAIN_INDICATOR',
    description: 'Cruise-main indicator',
    category: 'dynamics',
  ),
  _Sig(
    'inst_drive_power_limit_ind',
    'Instrument.INSTRUMENT_2IN1_FAULT_DRIVE_POWER_LIMIT_INDICATOR',
    description: 'Drive-power-limit indicator',
    category: 'propulsion',
  ),
  _Sig(
    'inst_discharge_ind',
    'Instrument.INSTRUMENT_2IN1_FAULT_DISCHARGE_INDICATOR',
    description: 'External-discharge indicator',
    category: 'charging',
  ),
  _Sig(
    'inst_epb_ind',
    'Instrument.INSTRUMENT_2IN1_FAULT_ELEC_PARKING_STATE_INDICATOR',
    description: 'EPB state indicator',
    category: 'propulsion',
  ),
  _Sig(
    'inst_oil_life_ind',
    'Instrument.INSTRUMENT_2IN1_FAULT_OIL_LIFE_DETECT_INDICATOR',
    description: 'Oil-life indicator',
    category: 'safety',
  ),
  _Sig(
    'inst_chg_connect_ind',
    'Instrument.INSTRUMENT_2IN1_FAULT_POWER_BATTERY_CHARGE_CONNECT_INDICATOR',
    description: 'Charge-connect indicator',
    category: 'charging',
  ),
  _Sig(
    'inst_gpf_ind',
    'Instrument.INSTRUMENT_2IN1_FAULT_GPF_INDICATOR',
    description: 'GPF (gasoline particulate filter) indicator',
    category: 'safety',
  ),
  _Sig(
    'inst_front_fog_ind',
    'Instrument.INSTRUMENT_2IN1_FAULT_FRONT_FOG_LIGHT_INDICATOR',
    description: 'Front-fog-light indicator',
    category: 'lights',
  ),
  _Sig(
    'inst_small_light_ind',
    'Instrument.INSTRUMENT_2IN1_FAULT_SMALL_LIGHT_INDICATOR',
    description: 'Small/position light indicator',
    category: 'lights',
  ),
  _Sig(
    'inst_main_alarm',
    'Instrument.INSTRUMENT_2IN1_FAULT_MAIN_ALARM_INDICATOR',
    description: 'Main alarm indicator',
    category: 'safety',
  ),
  _Sig(
    'inst_body_position',
    'Instrument.INSTRUMENT_2IN1_BODY_POSITION',
    description: 'Body-position indicator (3D)',
    category: 'safety',
  ),
  _Sig(
    'inst_dashboard_alarm',
    'Instrument.INSTRUMENT_2IN1_FAULT_DASHBOARD_ALARM',
    description: 'Cluster dashboard alarm',
    category: 'safety',
  ),
  _Sig(
    'inst_journey_mileage',
    'Instrument.INSTRUMENT_2IN1_CURRENT_JOURNEY_DRIVE_MILEAGE',
    description: 'Current-journey mileage',
    units: 'km',
    category: 'statistics',
  ),
  _Sig(
    'inst_journey_time',
    'Instrument.INSTRUMENT_2IN1_CURRENT_JOURNEY_DRIVE_TIME',
    description: 'Current-journey drive time',
    units: 'minutes',
    category: 'statistics',
  ),
  _Sig(
    'inst_journey_interface',
    'Instrument.INSTRUMENT_2IN1_CURRENT_JOURNEY_INTERFACE',
    description: 'Current-journey display interface',
    category: 'system',
  ),
  _Sig(
    'inst_acc_distance',
    'Instrument.INSTRUMENT_2IN1_ACC_DISTANCE',
    description: 'ACC distance setting (cluster)',
    category: 'adas',
  ),
  _Sig(
    'inst_acc_text_prompt',
    'Instrument.INSTRUMENT_2IN1_ACC_TEXT_PROMPT',
    description: 'ACC text prompt id',
    category: 'adas',
  ),
  _Sig(
    'inst_acc_time_dist',
    'Instrument.INSTRUMENT_2IN1_ACC_TIME_DISTANCE',
    description: 'ACC time-distance (gap setting)',
    category: 'adas',
  ),
  _Sig(
    'inst_acc_work_interface',
    'Instrument.INSTRUMENT_2IN1_ACC_WORK_INTERFACE',
    description: 'ACC work interface display state',
    category: 'adas',
  ),
  _Sig(
    'inst_dischg_mode',
    'Instrument.INSTRUMENT_2IN1_DISCHARGE_MODE',
    description: 'External-discharge mode (V2L)',
    category: 'charging',
  ),
  _Sig(
    'inst_dischg_energy',
    'Instrument.INSTRUMENT_2IN1_DISCHARGE_ELEC_ENERGY',
    description: 'External-discharge energy used',
    units: 'kwh',
    category: 'charging',
  ),
  _Sig(
    'inst_dischg_ui',
    'Instrument.INSTRUMENT_2IN1_DISCHARGE_UI',
    description: 'External-discharge UI state',
    category: 'charging',
  ),
  _Sig(
    'inst_dd_text_color',
    'Instrument.INSTRUMENT_DD_TEXT_COLOR',
    description: 'Cluster text colour theme',
    category: 'system',
  ),
  _Sig(
    'inst_dd_acc_speed_color',
    'Instrument.INSTRUMENT_DD_ACC_CRUISING_SPEED_COLOR',
    description: 'ACC cruise-speed colour theme',
    category: 'system',
  ),
  _Sig(
    'inst_charging_session_pct',
    'Statistic.STATISTIC_ELEC_PERCENTAGE',
    description: 'Battery percentage during charging session',
    units: 'percent',
    range: IntRange(0, 100),
    category: 'charging',
  ),

  // ── Settings (drive modes, units, language, screen) ───────────
  _Sig(
    'set_language',
    'Setting.SET_LANGUAGE_TYPE',
    description: 'UI language',
    category: 'settings',
    writeable: true,
    writeAction: 'settings.language.set',
  ),
  _Sig(
    'set_backlight_mcu',
    'Setting.SET_BACKLIGHT_BY_MCU',
    description: 'MCU-driven backlight level',
    units: 'percent',
    range: IntRange(0, 100),
    category: 'settings',
  ),
  _Sig(
    'set_ial_all_bright',
    'Setting.SET_IAL_ALL_BRIGHTNESS',
    description: 'All-ambient-light brightness',
    units: 'percent',
    range: IntRange(0, 100),
    category: 'cabin',
  ),
  _Sig(
    'set_ial_all_color',
    'Setting.SET_IAL_ALL_COLOR',
    description: 'All-ambient-light colour',
    category: 'cabin',
  ),
  _Sig(
    'set_ial_area_cfg',
    'Setting.SET_IAL_AREA_CONFIG',
    description: 'Ambient-light area config',
    category: 'cabin',
  ),
  _Sig(
    'set_ial_area_specific',
    'Setting.SET_IAL_AREA_SPECIFIC_CONFIG',
    description: 'Per-area ambient-light config',
    category: 'cabin',
  ),
  _Sig(
    'set_ial_bright_cfg',
    'Setting.SET_IAL_BRIGHTNESS_CONFIG',
    description: 'Ambient-light brightness configuration',
    category: 'cabin',
  ),
  _Sig(
    'set_ial_color_cfg',
    'Setting.SET_IAL_COLOR_CONFIG',
    description: 'Ambient-light colour configuration',
    category: 'cabin',
  ),
  _Sig(
    'set_drv_seat_heat',
    'Setting.SET_DRIVER_SEAT_HEATING_STATE',
    description: 'Driver-seat heating user state',
    category: 'climate',
  ),
  _Sig(
    'set_drv_seat_vent',
    'Setting.SET_DRIVER_SEAT_VENTILATING_STATE',
    description: 'Driver-seat ventilation user state',
    category: 'climate',
  ),
  _Sig(
    'set_pass_seat_heat',
    'Setting.SET_PASSENGER_SEAT_HEATING_STATE',
    description: 'Passenger-seat heating user state',
    category: 'climate',
  ),
  _Sig(
    'set_pass_seat_vent',
    'Setting.SET_PASSENGER_SEAT_VENTILATING_STATE',
    description: 'Passenger-seat ventilation user state',
    category: 'climate',
  ),
  _Sig(
    'set_rl_seat_heat',
    'Setting.SET_REAR_LEFT_SEAT_HEATING_STATE',
    description: 'Rear-left seat heating user state',
    category: 'climate',
  ),
  _Sig(
    'set_rr_seat_heat',
    'Setting.SET_REAR_RIGHT_SEAT_HEATING_STATE',
    description: 'Rear-right seat heating user state',
    category: 'climate',
  ),
  _Sig(
    'set_rl_seat_vent',
    'Setting.SET_REAR_LEFT_SEAT_VENTILATING_STATE',
    description: 'Rear-left seat ventilation user state',
    category: 'climate',
  ),
  _Sig(
    'set_rr_seat_vent',
    'Setting.SET_REAR_RIGHT_SEAT_VENTILATING_STATE',
    description: 'Rear-right seat ventilation user state',
    category: 'climate',
  ),
  _Sig(
    'set_drive_config_type',
    'Setting.SET_DRIVE_CONFIG_TYPE',
    description: 'Drive configuration type',
    category: 'propulsion',
  ),
  _Sig(
    'set_chg_port',
    'Setting.SET_DR_CHARGER_PORT',
    description: 'Selected charging port (left/right/dual)',
    category: 'charging',
  ),
  _Sig(
    'set_dr_st_assis',
    'Setting.SET_DR_ST_ASSIS',
    description: 'Driver steering-assist mode',
    category: 'dynamics',
  ),
  _Sig(
    'set_mode_button',
    'Setting.SET_MODE_BUTTON',
    description: 'Mode button state',
    category: 'propulsion',
  ),
  _Sig(
    'set_drv_massage_cfg',
    'Setting.SET_FRONT_LEFT_SEAT_MASSAGE_CONFIG',
    description: 'Driver seat massage hardware config',
    category: 'cabin',
  ),
  _Sig(
    'set_pass_massage_cfg',
    'Setting.SET_FRONT_RIGHT_SEAT_MASSAGE_CONFIG',
    description: 'Passenger seat massage hardware config',
    category: 'cabin',
  ),
  _Sig(
    'set_drv_hot_stone',
    'Setting.SET_MAIN_DRIVING_SEAT_HOT_STONE_MASSAGE_CONFIG',
    description: 'Driver hot-stone massage config',
    category: 'cabin',
  ),
  _Sig(
    'set_pass_hot_stone',
    'Setting.SET_PASSENGER_SEAT_HOT_STONE_MASSAGE_CONFIG',
    description: 'Passenger hot-stone massage config',
    category: 'cabin',
  ),
  _Sig(
    'set_drv_legrest_cfg',
    'Setting.SET_DRIVER_SEAT_LEGREST_CONFIG',
    description: 'Driver seat legrest hardware config',
    category: 'cabin',
  ),
  _Sig(
    'set_max_ev_memory',
    'Setting.SET_MAX_EV_MEMORY_STATE',
    description: 'Max-EV-range memory state',
    category: 'propulsion',
  ),
  _Sig(
    'set_max_ev_memory_guide',
    'Setting.SET_MAX_EV_MEMORY_GUIDE_STATE',
    description: 'Max-EV-range guide visibility',
    category: 'propulsion',
  ),
  _Sig(
    'set_steering_angle_ctrl',
    'Setting.SET_STEERING_WHEEL_ANGEL_CONTROL_STATE',
    description: 'Steering wheel angle control mode state',
    category: 'dynamics',
  ),

  // ── Audio / media ─────────────────────────────────────────────
  _Sig(
    'audio_master_volume',
    'Audio.AUDIO_MASTER_VOLUME_STATE',
    description: 'Master audio volume level',
    writeable: true,
    writeAction: 'audio.volume.set',
    // `_STATE` suffix — read-state mirror. Writes go through the
    // Android AudioManager binder (host-side), not a FAST wire row.
    binderOnly: true,
  ),
  _Sig(
    'audio_mute',
    'Audio.AUDIO_MUTE_STATUS',
    description: 'Master mute (0 off, 1 muted)',
    writeable: true,
    writeAction: 'audio.mute.toggle',
    // Same as audio_master_volume — read-state; writes via Android.
    binderOnly: true,
  ),
  _Sig(
    'audio_media_mute',
    'Audio.AUDIO_MEDIA_SOUND_MUTE_STATE',
    description: 'Media mute state',
  ),
  _Sig(
    'audio_media_source',
    'Audio.AUDIO_MEDIA_SOUND_SOURCE_STATE',
    description: 'Active media audio source',
  ),
  _Sig(
    'audio_media_source_change',
    'Audio.AUDIO_MEDIA_SOURCE_CHANGE',
    description: 'Media source change event',
  ),
  _Sig(
    'audio_media_source_armrest',
    'Audio.AUDIO_MEDIA_SOURCE_ARMREST_SCREEN',
    description: 'Armrest-screen media source',
  ),
  _Sig(
    'audio_media_volume_supp',
    'Audio.AUDIO_MEDIA_SOUND_VOLUME_SUPP_STATE',
    description: 'Media volume support state',
  ),
  _Sig(
    'audio_navi_volume',
    'Audio.AUDIO_NAVIGATION_VOLUME_STATE',
    description: 'Navigation prompt volume',
  ),
  _Sig(
    'audio_navi_mute',
    'Audio.AUDIO_NAVI_MUTE_STATUS',
    description: 'Navigation mute state',
  ),
  _Sig(
    'audio_navi_volume_new',
    'Audio.AUDIO_NEW_NAVIGATION_VOLUME_SET_STATUS',
    description: 'New-protocol navigation volume',
  ),
  _Sig(
    'audio_smart_voice_volume',
    'Audio.AUDIO_NEW_SMART_VOICE_VOLUME_SET_STATUS',
    description: 'Smart-voice prompt volume',
  ),
  _Sig(
    'audio_phone_volume',
    'Audio.AUDIO_PHONE_VOLUME_STATE',
    description: 'Phone-call volume',
  ),
  _Sig(
    'audio_phone_source',
    'Audio.AUDIO_PHONE_SOUND_SOURCE_STATE',
    description: 'Phone audio source state',
  ),
  _Sig(
    'audio_prompt_volume',
    'Audio.AUDIO_PROMPT_VOLUME_LEVEL_STATUS',
    description: 'System prompt volume',
  ),
  _Sig(
    'audio_channel',
    'Audio.AUDIO_CHANNEL',
    description: 'Active audio channel',
  ),
  _Sig(
    'audio_aux_state',
    'Audio.AUDIO_AUX_STATE',
    description: 'Aux input state',
  ),
  _Sig(
    'audio_bd_state',
    'Audio.AUDIO_BD_SOUND_SOURCE_STATE',
    description: 'Bluetooth/BD source state',
  ),
  _Sig(
    'audio_bluetooth_abnormal',
    'Audio.AUDIO_BLUETOOTH_MUSIC_PLAYBACK_ABNORMAL_STATUS',
    description: 'Bluetooth music playback abnormal',
  ),
  _Sig(
    'audio_radio_state',
    'Audio.AUDIO_RADAR_SOUND_SOURCE_STATE',
    description: 'Radar audio source state',
  ),
  _Sig(
    'audio_carplay_call',
    'Audio.AUDIO_CARPLAY_CALL_STATUS',
    description: 'Carplay call status',
  ),
  _Sig(
    'audio_bass',
    'Audio.AUDIO_BASS_SET_STATE',
    description: 'Bass set state',
  ),
  _Sig(
    'audio_midrange_treble',
    'Audio.AUDIO_MIDRANGE_TREBLE_STATUS',
    description: 'Midrange / treble setting',
  ),
  _Sig(
    'audio_acoustic_layout',
    'Audio.AUDIO_ACOUSTIC_LAYOUT',
    description: 'Acoustic layout (focus point)',
  ),
  _Sig(
    'audio_eq_freq_1',
    'Audio.AUDIO_EQUALIZER_FREQUENCY_1',
    description: 'Equaliser band 1',
  ),
  _Sig(
    'audio_eq_freq_2',
    'Audio.AUDIO_EQUALIZER_FREQUENCY_2',
    description: 'Equaliser band 2',
  ),
  _Sig(
    'audio_eq_freq_3',
    'Audio.AUDIO_EQUALIZER_FREQUENCY_3',
    description: 'Equaliser band 3',
  ),
  _Sig(
    'audio_eq_freq_4',
    'Audio.AUDIO_EQUALIZER_FREQUENCY_4',
    description: 'Equaliser band 4',
  ),
  _Sig(
    'audio_eq_freq_5',
    'Audio.AUDIO_EQUALIZER_FREQUENCY_5',
    description: 'Equaliser band 5',
  ),
  _Sig(
    'audio_3d_switch',
    'Audio.AUDIO_3D_SWITCH_STATUS',
    description: '3D sound switch',
  ),
  _Sig(
    'audio_3d_effect',
    'Audio.AUDIO_3D_SOUND_EFFECT_STATUS',
    description: '3D sound effect status',
  ),
  _Sig(
    'audio_3d_effect_cfg',
    'Audio.AUDIO_3D_SOUND_EFFECT_CONFIG',
    description: '3D sound effect configuration',
  ),
  _Sig(
    'audio_3d_prompt_source',
    'Audio.AUDIO_3D_PROMPT_TONE_SOURCE_STATUS',
    description: '3D prompt tone source status',
  ),
  _Sig(
    'audio_ai_spatial',
    'Audio.AUDIO_AI_SPATIAL_SOUND_CONFIG',
    description: 'AI spatial sound config',
  ),
  _Sig(
    'audio_amplifier_type',
    'Audio.AUDIO_AMPLIFIER_TYPE',
    description: 'Amplifier hardware type',
  ),
  _Sig(
    'audio_amplifier_cfg',
    'Audio.AUDIO_AMPLIFIER_CONFIG',
    description: 'Amplifier configuration',
  ),
  _Sig(
    'audio_anc_state',
    'Audio.AUDIO_ANC_SOUND_SOURCE_STATE',
    description: 'Active noise cancellation source state',
  ),
  _Sig(
    'audio_anc_cfg',
    'Audio.AUDIO_ANC_CONFIG',
    description: 'ANC configuration',
  ),
  _Sig(
    'audio_avas_source',
    'Audio.AUDIO_AVAS_SOUND_SOURCE_STATE',
    description: 'AVAS (exterior alert) source state',
  ),
  _Sig(
    'audio_avas_source_type',
    'Audio.AUDIO_AVAS_SOURCE_TYPE',
    description: 'AVAS source type',
  ),
  _Sig(
    'audio_avas_to_ext_speaker',
    'Audio.AUDIO_AVAS_AUDIO_SOURCE_TO_EXTERNAL_SPEAKER_STATUS',
    description: 'AVAS routing to external speaker',
  ),
  _Sig(
    'audio_avas_fault',
    'Audio.AUDIO_AVAS_FAULT_STATUS',
    description: 'AVAS fault status',
  ),
  _Sig(
    'audio_bass_speaker_state',
    'Audio.AUDIO_BASS_SPEAKER_WORKING_STATE',
    description: 'Bass speaker working state',
  ),
  _Sig(
    'audio_bass_speaker_fault',
    'Audio.AUDIO_BASS_SPEAKER_FAILURE_STATE',
    description: 'Bass speaker failure state',
  ),
  _Sig(
    'audio_ceiling_speaker_cfg',
    'Audio.AUDIO_CEILING_SPEAKER_CONFIG',
    description: 'Ceiling speaker hardware config',
  ),
  _Sig(
    'audio_backrow_communicate_vol',
    'Audio.AUDIO_BACKROW_INCAR_COMMUNICATE_VOLUME',
    description: 'Back-row in-car communicate volume',
  ),
  _Sig(
    'audio_incar_communicate_vol',
    'Audio.AUDIO_INCAR_COMMUNICATE_VOLUME',
    description: 'In-car communicate volume',
  ),
  _Sig(
    'audio_current_singer',
    'Audio.AUDIO_CURRENT_SINGER_NAME',
    description: 'Currently playing singer / artist name',
  ),
  _Sig(
    'audio_volume_max',
    'Audio.AUDIO_CURRENT_VOLUME_MAX_SET_GET',
    description: 'Current volume max bound',
  ),
  _Sig(
    'audio_volume_min',
    'Audio.AUDIO_CURRENT_VOLUME_MIN_SET_GET',
    description: 'Current volume min bound',
  ),
  _Sig(
    'audio_speed_volume_adj',
    'Audio.AUDIO_ADJ_VOLUME_WITH_SPEED',
    description: 'Speed-aware volume adjustment level',
  ),
  _Sig(
    'audio_headrest_volume_state',
    'Audio.AUDIO_HEADREST_SOUND_VOLUME_STATE',
    description: 'Headrest speaker volume state',
  ),
  _Sig(
    'audio_l_rear_headrest_vol',
    'Audio.AUDIO_LEFT_REAR_HEADREST_VOLUME_STATUS',
    description: 'Left-rear headrest speaker volume',
  ),
  _Sig(
    'audio_pass_headrest_vol',
    'Audio.AUDIO_PASSENGER_SEAT_HEADREST_VOLUME_STATUS',
    description: 'Passenger headrest speaker volume',
  ),
  _Sig(
    'audio_dynaudio_features',
    'Audio.AUDIO_DYNAUDIO_SOUND_FEATURES',
    description: 'Dynaudio sound features (EQ preset)',
  ),
  _Sig(
    'audio_dirac_live',
    'Audio.AUDIO_DIRAC_LIVE',
    description: 'Dirac Live processing state',
  ),
  _Sig(
    'audio_dirac_live_stage',
    'Audio.AUDIO_DIRAC_LIVE_STAGE',
    description: 'Dirac Live stage / soundstage mode',
  ),
  _Sig(
    'audio_has_dirac_stage',
    'Audio.AUDIO_HAS_DIRAC_LIVE_STAGE',
    description: 'Dirac Live stage hardware fitted',
  ),
  _Sig(
    'audio_devialet_125hz',
    'Audio.AUDIO_DEVIALET_SOUND_125HZ',
    description: 'Devialet 125Hz EQ band',
  ),
  _Sig(
    'audio_devialet_315hz',
    'Audio.AUDIO_DEVIALET_SOUND_315HZ',
    description: 'Devialet 315Hz EQ band',
  ),
  _Sig(
    'audio_devialet_800hz',
    'Audio.AUDIO_DEVIALET_SOUND_800HZ',
    description: 'Devialet 800Hz EQ band',
  ),
  _Sig(
    'audio_devialet_2000hz',
    'Audio.AUDIO_DEVIALET_SOUND_2000HZ',
    description: 'Devialet 2kHz EQ band',
  ),
  _Sig(
    'audio_devialet_5000hz',
    'Audio.AUDIO_DEVIALET_SOUND_5000HZ',
    description: 'Devialet 5kHz EQ band',
  ),
  _Sig(
    'audio_devialet_8000hz',
    'Audio.AUDIO_DEVIALET_SOUND_8000HZ',
    description: 'Devialet 8kHz EQ band',
  ),
  _Sig(
    'audio_devialet_50hz',
    'Audio.AUDIO_DEVIALET_SOUND_50HZ',
    description: 'Devialet 50Hz EQ band',
  ),
  _Sig(
    'audio_devialet_space',
    'Audio.AUDIO_DEVIALET_SPACE_SOUND',
    description: 'Devialet space-sound state',
  ),
  _Sig(
    'audio_dynarework_effect_cfg',
    'Audio.AUDIO_DYNA_REWORK_SOUND_EFFECT_CONFIG',
    description: 'Dyna-rework sound effect config',
  ),
  _Sig(
    'audio_dynarework_style',
    'Audio.AUDIO_DYNA_REWORK_SOUND_EFFECT_STYLE',
    description: 'Dyna-rework sound effect style',
  ),
  _Sig(
    'audio_intelligent_voice_source',
    'Audio.AUDIO_INTELLIGENT_VOICE_SOURCE_STATUS',
    description: 'Intelligent voice source status',
  ),
  _Sig(
    'audio_kara_ok_eq1',
    'Audio.AUDIO_KARA_OK_EQ1',
    description: 'Karaoke EQ band 1',
  ),
  _Sig(
    'audio_kara_ok_eq2',
    'Audio.AUDIO_KARA_OK_EQ2',
    description: 'Karaoke EQ band 2',
  ),
  _Sig(
    'audio_kara_ok_eq3',
    'Audio.AUDIO_KARA_OK_EQ3',
    description: 'Karaoke EQ band 3',
  ),
  _Sig(
    'audio_las_progress',
    'Audio.AUDIO_LAS_MUSIC_PLAYBACK_PROGRESS',
    description: 'LAS music playback progress',
    units: 'percent',
    range: IntRange(0, 100),
  ),

  // ── Power / system / OTA / time ───────────────────────────────
  _Sig(
    'power_acc',
    'Power.POWER_ACC_STATUS',
    description: 'Accessory power state',
  ),
  _Sig(
    'power_battery_remain',
    'Power.POWER_BATTERY_REMAIN_ELECTRICITY',
    description: 'Auxiliary 12V battery remaining',
  ),
  _Sig(
    'power_low_voltage',
    'Power.POWER_LOW_VOLTAGE',
    description: 'Low-voltage (12V) reading',
    units: 'volts',
  ),
  _Sig(
    'power_main_battery_v',
    'Power.POWER_MAIN_BATTERY_VOLTAGE_WOTKING_AREA',
    description: 'Main battery voltage working area',
    units: 'volts',
  ),
  _Sig(
    'power_motor',
    'Power.POWER_MOTOR_POWER',
    description: 'Motor power draw',
    units: 'kw',
  ),
  _Sig(
    'power_compressor',
    'Power.POWER_COMPRESSOR_CONSUME_POWER',
    description: 'Compressor power consumption',
    units: 'kw',
  ),
  _Sig(
    'power_ptc',
    'Power.POWER_PTC_CONSUME_POWER',
    description: 'PTC heater power consumption',
    units: 'kw',
  ),
  _Sig(
    'power_voltage_unbal',
    'Power.POWER_VOLTAGE_UNBALANCED_ALARM',
    description: 'Cell-voltage unbalanced alarm',
  ),
  _Sig(
    'power_self_awake',
    'Power.POWER_SELF_AWAKE_STATE',
    description: 'Vehicle self-wake state',
  ),
  _Sig(
    'power_extreme_endurance',
    'Power.POWER_EXTREME_ENDURANCE_STATUS',
    description: 'Extreme-endurance mode status',
  ),
  _Sig(
    'power_extreme_endurance_cfg',
    'Power.POWER_EXTREME_ENDURANCE_CONGIF',
    description: 'Extreme-endurance mode configured',
  ),
  _Sig(
    'power_long_press',
    'Power.POWER_BOARD_KEY_LONG_PRESS_POWER',
    description: 'Power-board long-press event',
  ),
  _Sig(
    'power_standby_battery',
    'Power.POWER_STANDBY_BATTERY_STATUS',
    description: 'Standby battery status',
  ),
  _Sig(
    'power_exterior_battery_1',
    'Power.POWER_EXTERIOR_BATTERY_POWER_1_STATUS',
    description: 'Exterior auxiliary battery 1 status',
  ),
  _Sig(
    'power_exterior_battery_2',
    'Power.POWER_EXTERIOR_BATTERY_POWER_2_STATUS',
    description: 'Exterior auxiliary battery 2 status',
  ),
  _Sig(
    'power_output_12v',
    'Power.POWER_OUTPUT_12V',
    description: '12V output rail state',
  ),
  _Sig(
    'power_output_5v',
    'Power.POWER_OUTPUT_5V',
    description: '5V output rail state',
  ),
  _Sig(
    'power_tft_backlight',
    'Power.POWER_TFT_BACKLIGHT',
    description: 'TFT panel backlight state',
  ),
  _Sig(
    'power_mcu_status',
    'Power.POWER_MCU_STATUS',
    description: 'Head-unit MCU status',
  ),
  _Sig(
    'power_l_sunlight_ad',
    'Power.POWER_LEFT_SIDE_SUNLIGHT_AD_VALUE',
    description: 'Left sunlight ADC value',
  ),
  _Sig(
    'power_r_sunlight_ad',
    'Power.POWER_RIGHT_SIDE_SUNLIGHT_AD_VALUE',
    description: 'Right sunlight ADC value',
  ),
  _Sig('ota_state', 'Ota.OTA_STATE', description: 'OTA update state'),
  _Sig(
    'ota_battery_voltage',
    'Ota.OTA_BATTERY_VOLTAGE',
    description: 'OTA battery voltage check',
    units: 'volts',
  ),
  _Sig(
    'ota_battery_power_voltage',
    'Ota.OTA_BATTERY_POWER_VOLTAGE',
    description: 'OTA battery power voltage',
    units: 'volts',
  ),
  _Sig(
    'ota_recovery_state',
    'Ota.OTA_RECOVERY_STATE',
    description: 'OTA recovery state',
  ),
  _Sig(
    'ota_smart_power_state',
    'Ota.OTA_SMART_POWER_PROCESS',
    description: 'OTA smart-power process state',
  ),
  _Sig(
    'ota_smart_power_error',
    'Ota.OTA_SMART_POWER_ERROR_REASON',
    description: 'OTA smart-power error reason',
  ),
  _Sig(
    'ota_version_check',
    'Ota.OTA_VEHICLE_OTA_VERSION_CHECK_SWITCH',
    description: 'OTA version check switch',
  ),
  _Sig(
    'ota_lf_door_lock',
    'Ota.OTA_LF_DOOR_LOCK',
    description: 'OTA front-left door lock state',
  ),
  _Sig(
    'ota_local_diag',
    'Ota.OTA_LOCAL_DIAG_STATUS',
    description: 'OTA local diagnostic status',
  ),
  _Sig(
    'ota_ipb_state',
    'Ota.OTA_IPB_SYSTEM_STATUS',
    description: 'OTA IPB system status',
  ),
  _Sig(
    'ota_dischg_contactor',
    'Ota.OTA_DISCHARGE_MAIN_CONTACTOR_STATE',
    description: 'OTA discharge main contactor state',
  ),
  _Sig('time_year', 'Time.TIME_YEAR', description: 'Vehicle clock year'),
  _Sig(
    'time_month',
    'Time.TIME_MONTH',
    description: 'Vehicle clock month',
    range: IntRange(1, 12),
  ),
  _Sig(
    'time_day',
    'Time.TIME_DAY',
    description: 'Vehicle clock day',
    range: IntRange(1, 31),
  ),
  _Sig(
    'time_hour',
    'Time.TIME_HOUR',
    description: 'Vehicle clock hour',
    range: IntRange(0, 23),
  ),
  _Sig(
    'time_minute',
    'Time.TIME_MINUTE',
    description: 'Vehicle clock minute',
    range: IntRange(0, 59),
  ),
  _Sig(
    'time_second',
    'Time.TIME_SECOND',
    description: 'Vehicle clock second',
    range: IntRange(0, 59),
  ),
  _Sig(
    'time_weekday',
    'Time.TIME_WEEKDAY',
    description: 'Vehicle clock weekday',
    range: IntRange(1, 7),
  ),
  _Sig('time_zone', 'Time.TIME_ZONE', description: 'Vehicle clock time zone'),
  _Sig(
    'time_summer',
    'Time.TIME_SUMMERTIME_STATE',
    description: 'Daylight-saving (summer-time) flag',
  ),
  _Sig(
    'time_format_24h',
    'Time.TIME_FORMAT_24H',
    description: 'Use 24-hour clock format',
  ),
  _Sig(
    'time_date_format',
    'Time.TIME_DATE_FORMAT',
    description: 'Date display format',
  ),
  _Sig(
    'time_changed',
    'Time.TIME_CHANGE',
    description: 'Time-change event (when clock was set)',
  ),
  _Sig(
    'time_request',
    'Time.TIME_TIME_REQUEST',
    description: 'Time-sync request signal',
  ),
  _Sig(
    'time_clock_style',
    'Time.TIME_CLOCK_SCREEN_CLOCK_STYLE',
    description: 'Clock-screen clock style',
  ),
  _Sig(
    'time_clock_dim',
    'Time.TIME_CLOCK_SCREEN_DIMMING_GEAR',
    description: 'Clock-screen dimming gear',
  ),
  _Sig(
    'time_clock_theme',
    'Time.TIME_CLOCK_SCREEN_THEME_WALLPAPER',
    description: 'Clock-screen theme wallpaper id',
  ),
  _Sig(
    'time_clock_tense',
    'Time.TIME_CLOCK_SCREEN_TENSE',
    description: 'Clock-screen tense / state',
  ),

  // ── Safety / TPMS / airbag / belts (expansion) ────────────────
  _Sig(
    'belt_alarm_switch',
    'Safety.SAFETY_BELT_ALARM_SWITCH',
    description: 'Seat-belt alarm switch enable',
  ),
  _Sig(
    'belt_lf_flag',
    'Safety.SAFETY_BELT_LF_FLAG',
    description: 'Driver belt flag (alternate)',
  ),
  _Sig(
    'belt_lr2_remind',
    'Safety.SAFETY_BELT_LR2_REMIND_STATUS',
    description: 'Rear-left seatbelt remind state',
  ),
  _Sig(
    'belt_mr2_remind',
    'Safety.SAFETY_BELT_MR2_REMIND_STATUS',
    description: 'Rear-centre seatbelt remind state',
  ),
  _Sig(
    'belt_rr2_remind',
    'Safety.SAFETY_BELT_RR2_REMIND_STATUS',
    description: 'Rear-right seatbelt remind state',
  ),
  _Sig(
    'belt_rr_remind',
    'Safety.SAFETY_BELT_RR_REMIND_STATUS',
    description: 'Rear seatbelt remind state',
  ),
  _Sig(
    'belt_reminder',
    'Safety.SAFETY_BELT_REMINDER',
    description: 'Generic belt reminder state',
  ),
  _Sig(
    'belt_msr_state',
    'Safety.SAFETY_BELT_MSR_STATE',
    description: 'Belt MSR sensor state',
  ),
  _Sig(
    'belt_passenger_2l',
    'Safety.SAFETY_BELT_PASSENGER_COMMAND_SECOND_ROW_SEAT_LEFT',
    description: 'Passenger 2nd-row left belt command',
  ),
  _Sig(
    'belt_passenger_2r',
    'Safety.SAFETY_BELT_PASSENGER_COMMAND_SECOND_ROW_SEAT_RIGHT',
    description: 'Passenger 2nd-row right belt command',
  ),
  _Sig(
    'belt_passenger_2m',
    'Safety.SAFETY_BELT_PASSENGER_COMMAND_SECOND_ROW_SEAT_MID',
    description: 'Passenger 2nd-row mid belt command',
  ),
  _Sig(
    'belt_passenger_1l',
    'Safety.SAFETY_BELT_PASSENGER_COMMAND_FRONT_ROW_SEAT_LEFT',
    description: 'Passenger front-row left belt command',
  ),
  _Sig(
    'belt_passenger_1r',
    'Safety.SAFETY_BELT_PASSENGER_COMMAND_FRONT_ROW_SEAT_RIGHT',
    description: 'Passenger front-row right belt command',
  ),
  _Sig(
    'belt_passenger_deputy',
    'Safety.SAFETY_BELT_PASSENGER_COMMAND_DEPUTY',
    description: 'Passenger deputy belt command',
  ),
  _Sig(
    'belt_row_l_2',
    'Safety.SAFETY_BELT_COMMAND_AREA_SECOND_ROW_SEAT_LEFT',
    description: '2nd-row left belt command area',
  ),
  _Sig(
    'belt_row_mid_2',
    'Safety.SAFETY_BELT_COMMAND_AREA_SECOND_ROW_SEAT_MID',
    description: '2nd-row middle belt command area',
  ),
  _Sig(
    'sensor_yaw_offset',
    'Sensor.SENSOR_YAW_RATE_OFFSET',
    description: 'Yaw-rate sensor offset',
  ),
  _Sig(
    'sensor_ax_ay_offset',
    'Sensor.SENSOR_AX_AY_OFFSET',
    description: 'Ax/Ay sensor offsets',
  ),
  _Sig(
    'sensor_humidity_fault',
    'Sensor.SENSOR_HUMIDITY_HARDWARE_FAILURE',
    description: 'Humidity sensor hardware failure',
  ),
  _Sig(
    'sensor_l_sunlight',
    'Sensor.SENSOR_LEFT_SUNLIGHT_INTENSITY',
    description: 'Left sunlight intensity',
  ),
  _Sig(
    'sensor_r_sunlight',
    'Sensor.SENSOR_RIGHT_SUNLIGHT_INTENSITY',
    description: 'Right sunlight intensity',
  ),
  _Sig(
    'sensor_sunlight_fault',
    'Sensor.SENSOR_SUNLIGHT_HARDWARE_FAILURE',
    description: 'Sunlight sensor failure',
  ),
  _Sig(
    'sensor_light_intensity',
    'Sensor.SENSOR_LIGHT_INTENSITY',
    description: 'Ambient light intensity',
  ),
  _Sig(
    'sensor_light_strength',
    'Sensor.SENSOR_LIGHT_STRENGTH',
    description: 'Ambient light strength gear',
  ),
  _Sig(
    'sensor_rainfall',
    'Sensor.SENSOR_RAIN_FALL_VALUE',
    description: 'Rain-sensor rainfall reading',
  ),
  _Sig(
    'sensor_windshield_temp',
    'Sensor.SENSOR_FRONT_WINDSHIELD_SURFACE_TEMP',
    description: 'Front-windshield surface temperature',
    units: 'celsius',
  ),
  _Sig(
    'sensor_windshield_humidity',
    'Sensor.SENSOR_FRONT_WINDSHIELD_HUMIDITY_VALUE',
    description: 'Front-windshield humidity reading',
  ),
  _Sig(
    'sensor_overload_alarm',
    'Sensor.SENSOR_OVERLOAD_ALARM_SIGNAL',
    description: 'Vehicle overload alarm signal',
  ),

  // ── Statistics (expansion) ────────────────────────────────────
  _Sig(
    'stat_dd_mileage1',
    'Statistic.STATISTIC_DD_MILEAGE1',
    description: 'Driver-display trip 1 odometer',
    units: 'km',
  ),
  _Sig(
    'stat_dd_mileage2',
    'Statistic.STATISTIC_DD_MILEAGE2',
    description: 'Driver-display trip 2 odometer',
    units: 'km',
  ),
  _Sig(
    'stat_total_mileage_m',
    'Statistic.STATISTIC_TOTAL_MILEAGE_METERS',
    description: 'Total mileage (metres precision)',
    units: 'km',
  ),
  _Sig(
    'stat_total_avg_speed',
    'Statistic.STATISTIC_TOTAL_AVERAGE_SPEED',
    description: 'Total average speed',
    units: 'km/h',
  ),
  _Sig(
    'stat_driving_time',
    'Statistic.STATISTIC_DRIVING_TIME',
    description: 'Total driving time (hours)',
    units: 'hours',
  ),
  _Sig(
    'stat_driving_time_min',
    'Statistic.STATISTIC_DRIVING_TIME_MINUTE',
    description: 'Driving time (minutes component)',
    units: 'minutes',
  ),
  _Sig(
    'stat_trip_total_elec',
    'Statistic.STATISTIC_THIS_TRIP_TOTAL_ELEC_CONSUMPTION',
    description: 'This trip total electric consumption',
    units: 'kwh',
  ),
  _Sig(
    'stat_trip_total_fuel',
    'Statistic.STATISTIC_THIS_TRIP_TOTAL_FUEL_CONSUMPTION',
    description: 'This trip total fuel consumption',
    units: 'litres',
  ),
  _Sig(
    'stat_mileage1_avg_speed',
    'Statistic.STATISTIC_MILEAGE1_AVERAGE_SPEED',
    description: 'Trip 1 average speed',
    units: 'km/h',
  ),
  _Sig(
    'stat_mileage1_drive_time',
    'Statistic.STATISTIC_MILEAGE1_DRIVE_TIME',
    description: 'Trip 1 drive time',
    units: 'minutes',
  ),
  _Sig(
    'stat_mileage1_elec',
    'Statistic.STATISTIC_MILEAGE1_ELEC_CONSUMPTION',
    description: 'Trip 1 electric consumption',
    units: 'kwh',
  ),
  _Sig(
    'stat_mileage1_fuel',
    'Statistic.STATISTIC_MILEAGE1_FULE_CONSUMPTION',
    description: 'Trip 1 fuel consumption',
    units: 'litres',
  ),
  _Sig(
    'stat_mileage1_elec_phkm',
    'Statistic.STATISTIC_MILEAGE1_ELEC_CON_PHKM',
    description: 'Trip 1 electric consumption per km',
  ),
  _Sig(
    'stat_mileage1_fuel_phkm',
    'Statistic.STATISTIC_MILEAGE1_FULE_CON_PHKM',
    description: 'Trip 1 fuel consumption per km',
  ),
  _Sig(
    'stat_mileage2_avg_speed',
    'Statistic.STATISTIC_MILEAGE2_AVERAGE_SPEED',
    description: 'Trip 2 average speed',
    units: 'km/h',
  ),
  _Sig(
    'stat_mileage2_drive_time',
    'Statistic.STATISTIC_MILEAGE2_DRIVE_TIME',
    description: 'Trip 2 drive time',
    units: 'minutes',
  ),
  _Sig(
    'stat_mileage2_elec',
    'Statistic.STATISTIC_MILEAGE2_ELEC_CONSUMPTION',
    description: 'Trip 2 electric consumption',
    units: 'kwh',
  ),
  _Sig(
    'stat_mileage2_fuel',
    'Statistic.STATISTIC_MILEAGE2_FULE_CONSUMPTION',
    description: 'Trip 2 fuel consumption',
    units: 'litres',
  ),
  _Sig(
    'stat_mileage2_elec_phkm',
    'Statistic.STATISTIC_MILEAGE2_ELEC_CON_PHKM',
    description: 'Trip 2 electric consumption per km',
  ),
  _Sig(
    'stat_mileage2_fuel_phkm',
    'Statistic.STATISTIC_MILEAGE2_FULE_CON_PHKM',
    description: 'Trip 2 fuel consumption per km',
  ),
  _Sig(
    'stat_instant_current',
    'Statistic.STATISTIC_INSTANTANEOUS_CURRENT',
    description: 'Instantaneous battery current',
    units: 'amps',
  ),
  _Sig(
    'stat_max_chg_current',
    'Statistic.STATISTIC_MAX_CHARGE_CURRENT_ALLOW',
    description: 'Max permitted charge current',
    units: 'amps',
  ),
  _Sig(
    'stat_ev_driving_mileage',
    'Statistic.STATISTIC_EV_DRIVING_MILEAGE',
    description: 'EV driving mileage (alias of stat_ev_km, more recent)',
    units: 'km',
  ),
  _Sig(
    'stat_endurance_increase',
    'Statistic.STATISTIC_ENDURANCE_INCREASE_MILEAGE',
    description: 'Endurance-increase mileage',
    units: 'km',
  ),
  _Sig(
    'stat_water_temperature',
    'Statistic.STATISTIC_WATER_TEMPERATURE',
    description: 'Engine water temperature (alias)',
    units: 'celsius',
  ),
  _Sig(
    'stat_50km_avg_fuel',
    'Statistic.STATISTIC_LAST_50KM_AVERAGE_FUEL_CON',
    description: 'Last 50km average fuel consumption',
  ),
  _Sig(
    'stat_50km_equal_fuel',
    'Statistic.STATISTIC_LAST_50KM_EQUAL_FUEL_CON',
    description: 'Last 50km equivalent fuel consumption',
  ),
  _Sig(
    'stat_speed_unit',
    'Statistic.STATISTIC_SPEED_UNIT',
    description: 'Vehicle-bus speed unit selection',
  ),
  _Sig(
    'stat_total_drive_unit',
    'Statistic.STATISTICS_TOTAL_DRIVING_RANGE_UNIT',
    description: 'Total driving range unit',
  ),
  _Sig(
    'stat_mileage_after_zero',
    'Statistic.STATISTICS_MILEAGE_AFTER_ZEROING',
    description: 'Mileage since last reset',
    units: 'km',
  ),
  _Sig(
    'stat_elec_after_zero',
    'Statistic.STATISTICS_ELECTRICITY_CONSUMPTION_AFTER_ZEROING',
    description: 'Electric consumption since last reset',
    units: 'kwh',
  ),
  _Sig(
    'stat_travel_time_h',
    'Statistic.STATISTICS_TRAVEL_TIME_AFTER_ZEROING_HOUR',
    description: 'Travel time since reset - hours',
    units: 'hours',
  ),
  _Sig(
    'stat_travel_time_m',
    'Statistic.STATISTICS_TRAVEL_TIME_AFTER_ZEROING_MINUTE',
    description: 'Travel time since reset - minutes',
    units: 'minutes',
  ),
  _Sig(
    'stat_target_wheel_torque',
    'Statistic.STATISTICS_VEHICLE_TARGET_WHEEL_TORQUE',
    description: 'Vehicle target wheel torque',
  ),
  _Sig(
    'stat_total_battery_consumption',
    'Statistic.STATISTICS_TOTAL_BATTERY_POWER_CONSUMPTION',
    description: 'Total battery energy consumption',
    units: 'kwh',
  ),
  _Sig(
    'stat_ac_pwr_50km',
    'Statistic.STATISTICS_AC_POWER_CONSUMPTION_50KM',
    description: 'AC power consumption over 50km',
  ),
  _Sig(
    'stat_ext_dischg_50km',
    'Statistic.STATISTICS_EXTERNAL_DISCHARGE_POWER_CONSUMPTION_50KM',
    description: 'External discharge consumption over 50km',
  ),
  _Sig(
    'stat_low_pwr_50km',
    'Statistic.STATISTICS_LOW_PRESSURE_POWER_CONSUMPTION_50KM',
    description: 'Low-voltage power consumption over 50km',
  ),
  _Sig(
    'stat_drive_pwr_50km',
    'Statistic.STATISTICS_POWER_DRIVE_POWER_CONSUMPTION_50KM',
    description: 'Drive power consumption over 50km',
  ),
  _Sig(
    'stat_low_energy_flag',
    'Statistic.STATISTICS_LOW_ENERGY_STATE_FLAG',
    description: 'Low-energy state flag',
  ),
  _Sig(
    'stat_navi_remaining_dist',
    'Statistic.STATISTICS_PEM_NAVIGATION_REMAINING_DISTANCE',
    description: 'Active navigation remaining distance',
    units: 'km',
  ),
  _Sig(
    'stat_navi_remaining_time',
    'Statistic.STATISTICS_PEM_NAVIGATION_REMAINING_TIME',
    description: 'Active navigation remaining time',
    units: 'minutes',
  ),
  _Sig(
    'stat_avg_ev_200m',
    'Statistic.STATISTICS_AVERAGE_INSTANT_EV_LAST_200M',
    description: 'Avg instant EV consumption last 200m',
  ),
  _Sig(
    'stat_avg_fuel_200m',
    'Statistic.STATISTICS_AVERAGE_INSTANT_FUEL_LAST_200M',
    description: 'Avg instant fuel consumption last 200m',
  ),
  _Sig(
    'stat_key_battery',
    'Statistic.STATISTIC_KEY_BATTERY_LEVEL',
    description: 'Key-fob battery level',
    units: 'percent',
    range: IntRange(0, 100),
  ),

  // ── Pm2.5 expansion ───────────────────────────────────────────
  _Sig(
    'pm25_value_in',
    'Pm2p5.PM2P5_VALUE_IN',
    description: 'Cabin PM2.5 (alias)',
  ),

  // ── Gb / charging-protocol (Chinese national standard) ────────
  _Sig(
    'gb_battery_voltage_alarm',
    'Gb.GB_BATTERY_VOLTAGE_HIGH_ALARM',
    description: 'GB battery voltage high alarm',
  ),
  _Sig(
    'gb_battery_voltage_low_alarm',
    'Gb.GB_BATTERY_VOLTATE_LOW_ALARM',
    description: 'GB battery voltage low alarm',
  ),
  _Sig(
    'gb_battery_overcharge',
    'Gb.GB_BATTERY_OVERCHARGE',
    description: 'GB battery overcharge alarm',
  ),
  _Sig(
    'gb_battery_consistency',
    'Gb.GB_BATTERY_POOR_CONSISTENCY_ALARM',
    description: 'GB battery poor consistency alarm',
  ),
  _Sig(
    'gb_battery_high_temp',
    'Gb.GB_BATTERY_HIGH_TEMP_ALARM',
    description: 'GB battery high-temperature alarm',
  ),
  _Sig(
    'gb_battery_level_alarm',
    'Gb.GB_BATTERY_LEVEL_ALARM',
    description: 'GB battery low-level alarm',
  ),
  _Sig(
    'gb_battery_current',
    'Gb.GB_BATTERY_CCURRENT',
    description: 'GB pack current',
    units: 'amps',
  ),
  _Sig(
    'gb_battery_probe_num',
    'Gb.GB_BATTERY_PROBE_NUM',
    description: 'GB battery probe count',
  ),
  _Sig(
    'gb_bmc_insulation',
    'Gb.GB_BMC_INSULATION_VALUE',
    description: 'BMC insulation resistance',
  ),
  _Sig(
    'gb_dc_charging_fault',
    'Gb.GB_DC_CHARGING_FAULT',
    description: 'GB DC charging fault code',
  ),
  _Sig(
    'gb_dc_rated_power',
    'Gb.GB_DC_RATED_POWER',
    description: 'GB DC rated power',
    units: 'kw',
  ),
  _Sig(
    'gb_dm_platform',
    'Gb.GB_DM_PLATFORM',
    description: 'GB DM platform code',
  ),
  _Sig(
    'gb_front_motor_voltage',
    'Gb.GB_FRONT_MOTOR_BUS_VOLTAGE',
    description: 'GB front-motor bus voltage',
    units: 'volts',
  ),
  _Sig(
    'gb_front_motor_temp',
    'Gb.GB_FRONT_MOTOR_IPM_TEMP',
    description: 'GB front-motor IPM temperature',
    units: 'celsius',
  ),
  _Sig(
    'gb_ev_func_limit',
    'Gb.GB_EV_FUNCTION_LIMITED_240',
    description: 'GB EV-function limited flag',
  ),
  _Sig(
    'gb_2in1_total_mileage',
    'Gb.GB_2IN1_TOTAL_MILEAGE',
    description: 'GB 2-in-1 total mileage',
    units: 'km',
  ),
  _Sig(
    'gb_ac_work_cmd',
    'Gb.GB_AIR_CONDITIONING_WORKING_COMMAND',
    description: 'GB AC working command',
  ),
  _Sig(
    'gb_battery_version',
    'Gb.GB_BATTERY_VERSION_FLAG',
    description: 'GB battery version flag',
  ),
  _Sig(
    'gb_charging_failure_10',
    'Gb.GB_CHARGING_SYSTEM_FAILURE_10',
    description: 'GB charging system failure 0x10',
  ),
  _Sig(
    'gb_charging_failure_20',
    'Gb.GB_CHARGING_SYSTEM_FAILURE_20',
    description: 'GB charging system failure 0x20',
  ),
  _Sig(
    'gb_dc_system_failure',
    'Gb.GB_DC_SYSTEM_FAILURE',
    description: 'GB DC system failure',
  ),

  // ── Wiper (expansion) ─────────────────────────────────────────
  _Sig(
    'wiper_r_wash_gear',
    'Wiper.WIPER_REAR_WIPER_WASH_GEAR',
    description: 'Rear wiper washer gear level',
  ),
  _Sig(
    'wiper_sensitivity',
    'Wiper.WIPER_WINDSCREEN_WIPER_SENSITIVITY',
    description: 'Auto-wiper rain sensitivity',
  ),
  // ── Status-read-only signals ──────────────────────────────────
  // Read by the Kotlin status path (StatusKeyCatalog is generated from
  // [_statusFacet] + these rows) but previously absent from the public
  // catalog. Listed here so the catalog is the single source for every
  // label↔framework pair; read-only, no UI metadata.
  _Sig('ac_quick_clean_3da_online', 'Ac.AC_QUICK_CLEAN_AIR_3DA_ONLINE'),
  _Sig('ac_quick_clean_tip', 'Ac.AC_QUICK_CLEAN_AIR_TIP'),
  _Sig('chg_eta_change', 'Charging.CHARGING_FULL_REST_TIME_CHANGE'),
  _Sig('energy_mode_ic', 'Energy.ENERGY_MODE_INSTRUMENT'),
  _Sig('location_change', 'Location.LOCATION_CHANGE'),
  _Sig('ota_batt_v', 'Ota.OTA_BATTERY_VOLTAGE'),
  _Sig('ota_batt_power_v', 'Ota.OTA_BATTERY_POWER_VOLTAGE'),
  _Sig('panorama_output', 'Panorama.PANORAMA_OUTPUT_STATE'),
  _Sig('panorama_work', 'Panorama.PANORAMA_WORK_MODE'),
  _Sig('pm25_changed', 'Pm2p5.PM2P5_VALUE_CHANGED'),
  _Sig('radar_probe_l', 'Radar.RADAR_PROBE_STATE_LEFT'),
  _Sig('radar_probe_r', 'Radar.RADAR_PROBE_STATE_RIGHT'),
  _Sig('radar_probe_lf', 'Radar.RADAR_PROBE_STATE_LEFT_FRONT'),
  _Sig('radar_probe_lr', 'Radar.RADAR_PROBE_STATE_LEFT_REAR'),
  _Sig('radar_probe_rr', 'Radar.RADAR_PROBE_STATE_RIGHT_REAR'),
  _Sig('radar_probe_flm', 'Radar.RADAR_PROBE_STATE_FRONT_LEFT_MID'),
  _Sig('radar_probe_frm', 'Radar.RADAR_PROBE_STATE_FRONT_RIGHT_MID'),
  _Sig('belt_pass_deputy', 'Safety.SAFETY_BELT_PASSENGER_COMMAND_DEPUTY'),
  _Sig(
    'belt_pass_row_l',
    'Safety.SAFETY_BELT_PASSENGER_COMMAND_SECOND_ROW_SEAT_LEFT',
  ),
  _Sig(
    'belt_pass_row_mid',
    'Safety.SAFETY_BELT_PASSENGER_COMMAND_SECOND_ROW_SEAT_MID',
  ),
  _Sig(
    'belt_pass_row_r',
    'Safety.SAFETY_BELT_PASSENGER_COMMAND_SECOND_ROW_SEAT_RIGHT',
  ),
  _Sig('stat_elec_pct', 'Statistic.STATISTIC_ELEC_PERCENTAGE'),
  _Sig('tyre_pressure_lf', 'Tyre.TYRE_PRESSURE_VALUE_LEFT_FRONT'),
  _Sig('tyre_pressure_rf', 'Tyre.TYRE_PRESSURE_VALUE_RIGHT_FRONT'),
  _Sig('tyre_pressure_lr', 'Tyre.TYRE_PRESSURE_VALUE_LEFT_REAR'),
  _Sig('tyre_pressure_rr', 'Tyre.TYRE_PRESSURE_VALUE_RIGHT_REAR'),
];

/// Brand-neutral name -> framework name map. Built once at startup
/// from [_entries]. Exported for legacy call sites that still
/// import [bydStatusLabelToCatalog] from `byd_status_labels.dart`.
final Map<String, String> bydStatusLabelToCatalog =
    Map<String, String>.unmodifiable(<String, String>{
      for (final e in _entries) e.name: e.framework,
    });

/// Boot warmup set - the catalog names every dashboard surface
/// needs on first paint. Kept tight so a single batched daemon
/// round-trip stays well inside the fast timeout budget (~3 s).
const List<String> bydBootWarmSet = [
  // Doors / closures
  'Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR',
  'Bodywork.BODYWORK_RIGHT_HAND_FRONT_DOOR',
  'Bodywork.BODYWORK_LEFT_HAND_REAR_DOOR',
  'Bodywork.BODYWORK_RIGHT_HAND_REAR_DOOR',
  'Bodywork.BODYWORK_LUGGAGE_DOOR',
  'Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT',
  // Climate
  'Ac.AC_POWER_STATE',
  'Ac.AC_WIND_LEVEL',
  'Ac.AC_TEMP_MAIN',
  'Ac.AC_TEMP_INSIDE',
  'Instrument.INSTRUMENT_DD_OUT_TEMP',
  // Lights
  'Light.LIGHT_LOW_BEAM_LIGHT',
  'Light.LIGHT_HIGH_BEAM_LIGHT',
  'Light.LIGHT_FRONT_FOG_LIGHT',
  'Light.LIGHT_REAR_FOG_LIGHT',
  'Instrument.INSTRUMENT_SMART_KEY_SYS_WARN_LIGHT',
  // Powertrain / dynamics
  'Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE',
  'Statistic.STATISTIC_ELEC_DRIVING_RANGE',
  'Statistic.STATISTIC_FUEL_DRIVING_RANGE',
  'Statistic.STATISTIC_SPEED_SIG_VDIS',
  'Instrument.INSTRUMENT_EV_MODE_INDICATORE',
  'Instrument.INSTRUMENT_HEV_MODE_INDICATORE',
];

/// BYD implementation of [PublicCatalog]. Reads [_entries] directly
/// so adding a row is a one-line change.
class BydPublicCatalog implements PublicCatalog {
  BydPublicCatalog._(this._byName, this._byCategory, this._categories);

  /// Process-wide memoised build. The catalog is derived from the const
  /// [_entries] table and is immutable (reads only), so building it once
  /// and sharing it is safe — and avoids re-walking ~6k entries on every
  /// call. Previously each command-builder domain file (climate/seats/
  /// lights) + the provider rebuilt it independently at registry init, so
  /// the O(entries) walk ran several times at boot.
  factory BydPublicCatalog.build() => _cached ??= BydPublicCatalog._build();

  static BydPublicCatalog? _cached;

  factory BydPublicCatalog._build() {
    final entries = <String, PublicCatalogEntry>{};
    final byCat = <String, List<PublicCatalogEntry>>{};

    for (final sig in _entries) {
      final entry = _toPublicEntry(sig);
      entries[sig.name] = entry;
      (byCat[entry.category] ??= <PublicCatalogEntry>[]).add(entry);
    }

    final cats = byCat.keys.toList()..sort();
    return BydPublicCatalog._(entries, byCat, cats);
  }

  final Map<String, PublicCatalogEntry> _byName;
  final Map<String, List<PublicCatalogEntry>> _byCategory;
  final List<String> _categories;

  @override
  int get size => _byName.length;

  @override
  Iterable<PublicCatalogEntry> all() => _byName.values;

  @override
  PublicCatalogEntry? get(String name) => _byName[name];

  @override
  Iterable<PublicCatalogEntry> byCategory(String category) =>
      _byCategory[category] ?? const <PublicCatalogEntry>[];

  @override
  Iterable<PublicCatalogEntry> threeD() =>
      _byName.values.where((e) => e.threeD);

  @override
  List<String> categories() => List<String>.unmodifiable(_categories);
}

PublicCatalogEntry _toPublicEntry(_Sig s) {
  return PublicCatalogEntry(
    name: s.name,
    category: s.category ?? _inferCategory(s.name),
    description: s.description ?? _humanise(s.name),
    units: s.units,
    range: s.range,
    writeable: s.writeable,
    writeActionId: s.writeAction,
    wireActionId: s.wireActionId,
    binderOnly: s.binderOnly,
    threeD: s.threeD,
  );
}

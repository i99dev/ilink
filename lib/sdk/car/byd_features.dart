/// BYD-specific catalog name constants — single source of truth
/// for the catalog strings widgets reference.
///
/// Generated from `.secrets/byd/catalog_meta.yaml`. To regenerate
/// after editing the meta file:
///
/// ```sh
/// dart run tool/gen_byd_features.dart
/// ```
///
/// Each constant is the verbatim catalog name; widgets use them
/// via `featureValueProvider(BydFeatures.<name>)`.
library;

/// Curated catalog names — only the entries documented in
/// catalog_meta.yaml. To use a name not in this set, pass the
/// raw string to featureValueProvider — but consider adding it
/// to catalog_meta.yaml + this file so other widgets can find it.
class BydFeatures {
  BydFeatures._();

  /// Driver seat heat level
  static const acMainDriveSeatHeatingLevel =
      'Ac.AC_MAIN_DRIVE_SEAT_HEATING_LEVEL';

  /// Driver seat ventilation level
  static const acMainDriveSeatVentilatingLevel =
      'Ac.AC_MAIN_DRIVE_SEAT_VENTILATING_LEVEL';

  /// Passenger seat heat level
  static const acPassengerSeatHeatingLevel =
      'Ac.AC_PASSENGER_SEAT_HEATING_LEVEL';

  /// Passenger seat ventilation level
  static const acPassengerSeatVentilatingLevel =
      'Ac.AC_PASSENGER_SEAT_VENTILATING_LEVEL';

  /// AC system power state
  static const acPowerState = 'Ac.AC_POWER_STATE';

  /// Rear-left seat heat level
  static const acRearLeftSeatHeatingLevel =
      'Ac.AC_REAR_LEFT_SEAT_HEATING_LEVEL';

  /// Rear-right seat heat level
  static const acRearRightSeatHeatingLevel =
      'Ac.AC_REAR_RIGHT_SEAT_HEATING_LEVEL';

  /// Cabin temperature (°C)
  static const acTempInside = 'Ac.AC_TEMP_INSIDE';

  /// AC setpoint (driver zone) (°C)
  static const acTempMain = 'Ac.AC_TEMP_MAIN';

  /// Fan speed level
  static const acWindLevel = 'Ac.AC_WIND_LEVEL';

  /// Wind direction mode
  static const acWindMode = 'Ac.AC_WIND_MODE';

  /// Driver door open state
  static const bodyworkLeftHandFrontDoor =
      'Bodywork.BODYWORK_LEFT_HAND_FRONT_DOOR';

  /// Rear-left door open state
  static const bodyworkLeftHandRearDoor =
      'Bodywork.BODYWORK_LEFT_HAND_REAR_DOOR';

  /// Trunk open state
  static const bodyworkLuggageDoor = 'Bodywork.BODYWORK_LUGGAGE_DOOR';

  /// Passenger door open state
  static const bodyworkRightHandFrontDoor =
      'Bodywork.BODYWORK_RIGHT_HAND_FRONT_DOOR';

  /// Rear-right door open state
  static const bodyworkRightHandRearDoor =
      'Bodywork.BODYWORK_RIGHT_HAND_REAR_DOOR';

  /// Current charging power (kW)
  static const chargingPower = 'Charging.CHARGING_POWER';

  /// Vehicle lock state (master via driver-door actuator)
  static const doorLockCommandAreaLeftFront =
      'Door.DOOR_LOCK_COMMAND_AREA_LEFT_FRONT';

  /// Tyre pressure (left rear) (kPa)
  static const instrument2in1LbTyrePressure =
      'Instrument.INSTRUMENT_2IN1_LB_TYRE_PRESSURE';

  /// Tyre pressure (left front) (kPa)
  static const instrument2in1LfTyrePressure =
      'Instrument.INSTRUMENT_2IN1_LF_TYRE_PRESSURE';

  /// Tyre pressure (right rear) (kPa)
  static const instrument2in1RbTyrePressure =
      'Instrument.INSTRUMENT_2IN1_RB_TYRE_PRESSURE';

  /// Tyre pressure (right front) (kPa)
  static const instrument2in1RfTyrePressure =
      'Instrument.INSTRUMENT_2IN1_RF_TYRE_PRESSURE';

  /// Outside ambient temperature (°C)
  static const instrumentDdOutTemp = 'Instrument.INSTRUMENT_DD_OUT_TEMP';

  /// EV drive mode active indicator
  static const instrumentEvModeIndicatore =
      'Instrument.INSTRUMENT_EV_MODE_INDICATORE';

  /// HEV drive mode active indicator
  static const instrumentHevModeIndicatore =
      'Instrument.INSTRUMENT_HEV_MODE_INDICATORE';

  /// Headlight master indicator (DRL / position / smart-key warn)
  static const instrumentSmartKeySysWarnLight =
      'Instrument.INSTRUMENT_SMART_KEY_SYS_WARN_LIGHT';

  /// Front fog light
  static const lightFrontFogLight = 'Light.LIGHT_FRONT_FOG_LIGHT';

  /// High-beam headlight
  static const lightHighBeamLight = 'Light.LIGHT_HIGH_BEAM_LIGHT';

  /// Low-beam headlight
  static const lightLowBeamLight = 'Light.LIGHT_LOW_BEAM_LIGHT';

  /// Rear fog light
  static const lightRearFogLight = 'Light.LIGHT_REAR_FOG_LIGHT';

  /// EV driving range (km)
  static const statisticElecDrivingRange =
      'Statistic.STATISTIC_ELEC_DRIVING_RANGE';

  /// Fuel driving range (PHEV / ICE) (km)
  static const statisticFuelDrivingRange =
      'Statistic.STATISTIC_FUEL_DRIVING_RANGE';

  /// Battery state of charge (%)
  static const statisticSocBatteryPercentage =
      'Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE';

  /// Vehicle speed (speedometer display value) (km/h)
  static const statisticSpeedSigVdis = 'Statistic.STATISTIC_SPEED_SIG_VDIS';
}

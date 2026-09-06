/// Sub-domain state classes that mirror BYD's `BYDAutoFeatureIds`
/// catalog. Each gate owns one car-data domain; [CarGate] is the
/// aggregate the rest of the app reads.
///
/// Wire format: every gate has a `fromRaw(Map<String, dynamic>)`
/// factory that reads the snake_case keys produced by
/// `AutoFeatureService.readStatus()` Kotlin-side. The raw key names
/// are documented inline next to each field so anyone extending the
/// Kotlin side knows exactly which key to publish.
///
/// "❓" markers in the field doc-comments mean the key isn't yet
/// produced by the host — the diagnostic screen will show those
/// fields as "never received". Adding host-side support is mechanical:
/// add the BYD feature-ID read in `AutoFeatureService.readStatus()`
/// and publish the result under the snake_case key documented here.
library;

import 'package:flutter/foundation.dart';

// ─── Connection ─────────────────────────────────────────────────────

/// Bridge / daemon health. Not from BYD — synthesised from the
/// platform channel state.
@immutable
class ConnectionGate {
  const ConnectionGate({
    this.adbConnected = false,
    this.daemonReady = false,
    this.lastPushAt,
  });

  final bool adbConnected;
  final bool daemonReady;
  final DateTime? lastPushAt;

  static ConnectionGate fromRaw(Map<String, dynamic> raw) => ConnectionGate(
    adbConnected: raw['adbConnected'] == true,
    daemonReady: raw['daemonReady'] == true,
    lastPushAt: DateTime.now(),
  );
}

// ─── Closures (doors / windows / hood / trunk / sunroof / fuel cap) ─

@immutable
class ClosuresGate {
  const ClosuresGate({
    // Doors
    this.doorLock,
    this.doorLf,
    this.doorRf,
    this.doorLr,
    this.doorRr,
    // Per-door lock state
    this.lockLf,
    this.lockRf,
    this.lockLr,
    this.lockRr,
    this.lockBack,
    this.childLockLeft,
    this.childLockRight,
    // Trunk / hood / fuel cap
    this.trunk,
    this.hood,
    this.fuelCap,
    // Windows (state + position 0-100)
    this.windowLf,
    this.windowRf,
    this.windowLr,
    this.windowRr,
    this.windowLfPct,
    this.windowRfPct,
    this.windowLrPct,
    this.windowRrPct,
    // Sunroof / shade
    this.moonRoof,
    this.moonRoofPct,
    this.sunshade,
    this.sunshadePct,
    // Rain auto-close toggle
    this.rainAutoClose,
  });

  final int? doorLock; // raw: door_lock          ✅
  final int? doorLf; // raw: door_lf            ✅
  final int? doorRf; // raw: door_rf            ✅
  final int? doorLr; // raw: door_lr            ✅
  final int? doorRr; // raw: door_rr            ✅

  final int? lockLf; // raw: lock_lf            ❓
  final int? lockRf; // raw: lock_rf            ❓
  final int? lockLr; // raw: lock_lr            ❓
  final int? lockRr; // raw: lock_rr            ❓
  final int? lockBack; // raw: lock_back          ❓
  final int? childLockLeft; // raw: child_lock_l    ❓
  final int? childLockRight; // raw: child_lock_r    ❓

  final int? trunk; // raw: trunk              ✅
  final int? hood; // raw: hood               ❓
  final int? fuelCap; // raw: fuel_cap           ❓

  final int? windowLf; // raw: window_lf          ❓
  final int? windowRf; // raw: window_rf          ❓
  final int? windowLr; // raw: window_lr          ❓
  final int? windowRr; // raw: window_rr          ❓
  final int? windowLfPct; // raw: window_lf_pct      ❓
  final int? windowRfPct; // raw: window_rf_pct      ❓
  final int? windowLrPct; // raw: window_lr_pct      ❓
  final int? windowRrPct; // raw: window_rr_pct      ❓

  final int? moonRoof; // raw: moon_roof          ❓
  final int? moonRoofPct; // raw: moon_roof_pct      ❓
  final int? sunshade; // raw: sunshade           ❓
  final int? sunshadePct; // raw: sunshade_pct       ❓

  final int? rainAutoClose; // raw: rain_auto_close   ❓

  static ClosuresGate fromRaw(Map<String, dynamic> raw) {
    int? r(String k) => raw[k] as int?;
    return ClosuresGate(
      doorLock: r('door_lock'),
      doorLf: r('door_lf'),
      doorRf: r('door_rf'),
      doorLr: r('door_lr'),
      doorRr: r('door_rr'),
      lockLf: r('lock_lf'),
      lockRf: r('lock_rf'),
      lockLr: r('lock_lr'),
      lockRr: r('lock_rr'),
      lockBack: r('lock_back'),
      childLockLeft: r('child_lock_l'),
      childLockRight: r('child_lock_r'),
      trunk: r('trunk'),
      hood: r('hood'),
      fuelCap: r('fuel_cap'),
      windowLf: r('window_lf'),
      windowRf: r('window_rf'),
      windowLr: r('window_lr'),
      windowRr: r('window_rr'),
      windowLfPct: r('window_lf_pct'),
      windowRfPct: r('window_rf_pct'),
      windowLrPct: r('window_lr_pct'),
      windowRrPct: r('window_rr_pct'),
      moonRoof: r('moon_roof'),
      moonRoofPct: r('moon_roof_pct'),
      sunshade: r('sunshade'),
      sunshadePct: r('sunshade_pct'),
      rainAutoClose: r('rain_auto_close'),
    );
  }
}

// ─── Climate (AC) ───────────────────────────────────────────────────

@immutable
class ClimateGate {
  const ClimateGate({
    this.acPower,
    this.fanLevel,
    this.windMode,
    this.cycleMode,
    this.ctrlMode, // auto / manual
    this.compressorMode, // ac compressor on/off
    this.targetTempC,
    this.targetTempCoC, // passenger temp setpoint
    this.targetTempRearC, // rear zone temp setpoint
    this.cabinTempC,
    this.outsideTempC,
    this.tempUnit, // C vs F
    this.defrostFront,
    this.defrostRear,
    this.maxCooling,
    this.ventilation,
    this.rearPower,
    this.tempCtrlSeparate, // sync vs separate L/R
    this.quickCleanAir,
    this.autoCleanAir,
  });

  final bool? acPower; // raw: ac_power            ✅ (boolean from int)
  final int? fanLevel; // raw: ac_fan              ✅
  final int? windMode; // raw: ac_wind_mode        ✅
  final int? cycleMode; // raw: ac_cycle            ✅
  final int? ctrlMode; // raw: ac_ctrl_mode        ❓
  final int? compressorMode; // raw: ac_compressor       ❓
  final int? targetTempC; // raw: ac_target_temp      ✅
  final int? targetTempCoC; // raw: ac_target_temp_co   ❓
  final int? targetTempRearC; // raw: ac_target_temp_rear ❓
  final int? cabinTempC; // raw: ac_cabin_temp       ✅
  final int? outsideTempC; // raw: ac_temp_out         ✅
  final int? tempUnit; // raw: ac_temp_unit        ❓
  final int? defrostFront; // raw: ac_defrost_f        ❓
  final int? defrostRear; // raw: ac_defrost_r        ❓
  final int? maxCooling; // raw: ac_max_cool         ❓
  final int? ventilation; // raw: ac_vent             ❓
  final int? rearPower; // raw: ac_rear_power       ❓
  final int? tempCtrlSeparate; // raw: ac_temp_separate    ❓
  final int? quickCleanAir; // raw: ac_quick_clean      ❓
  final int? autoCleanAir; // raw: ac_auto_clean       ❓

  static ClimateGate fromRaw(Map<String, dynamic> raw) {
    int? r(String k) => raw[k] as int?;
    final acPowerRaw = r('ac_power');
    return ClimateGate(
      acPower: acPowerRaw == null ? null : acPowerRaw == 1,
      fanLevel: r('ac_fan'),
      windMode: r('ac_wind_mode'),
      cycleMode: r('ac_cycle'),
      ctrlMode: r('ac_ctrl_mode'),
      compressorMode: r('ac_compressor'),
      targetTempC: r('ac_target_temp'),
      targetTempCoC: r('ac_target_temp_co'),
      targetTempRearC: r('ac_target_temp_rear'),
      cabinTempC: r('ac_cabin_temp'),
      outsideTempC: r('ac_temp_out'),
      tempUnit: r('ac_temp_unit'),
      defrostFront: r('ac_defrost_f'),
      defrostRear: r('ac_defrost_r'),
      maxCooling: r('ac_max_cool'),
      ventilation: r('ac_vent'),
      rearPower: r('ac_rear_power'),
      tempCtrlSeparate: r('ac_temp_separate'),
      quickCleanAir: r('ac_quick_clean'),
      autoCleanAir: r('ac_auto_clean'),
    );
  }
}

// ─── Lights (exterior) ──────────────────────────────────────────────

@immutable
class LightsGate {
  const LightsGate({
    this.headlight,
    this.lowBeam,
    this.highBeam,
    this.frontFog,
    this.rearFog,
    this.turnLeft,
    this.turnRight,
    this.turnSignalCombined,
    this.dayRunning,
    this.footLight,
    this.sideLight,
    this.stalkPositionLeft,
    this.stalkPositionRight,
  });

  final int? headlight; // raw: headlight         ✅
  final int? lowBeam; // raw: low_beam          ✅
  final int? highBeam; // raw: high_beam         ✅
  final int? frontFog; // raw: front_fog         ✅
  final int? rearFog; // raw: rear_fog          ✅
  final int? turnLeft; // raw: turn_left         ❓
  final int? turnRight; // raw: turn_right        ❓
  final int? turnSignalCombined; // raw: turn_signal       ❓
  final int? dayRunning; // raw: drl               ❓
  final int? footLight; // raw: foot_light        ❓
  final int? sideLight; // raw: side_light        ❓
  final int? stalkPositionLeft; // raw: stalk_l           ❓
  final int? stalkPositionRight; // raw: stalk_r           ❓

  static LightsGate fromRaw(Map<String, dynamic> raw) {
    int? r(String k) => raw[k] as int?;
    return LightsGate(
      headlight: r('headlight'),
      lowBeam: r('low_beam'),
      highBeam: r('high_beam'),
      frontFog: r('front_fog'),
      rearFog: r('rear_fog'),
      turnLeft: r('turn_left'),
      turnRight: r('turn_right'),
      turnSignalCombined: r('turn_signal'),
      dayRunning: r('drl'),
      footLight: r('foot_light'),
      sideLight: r('side_light'),
      stalkPositionLeft: r('stalk_l'),
      stalkPositionRight: r('stalk_r'),
    );
  }
}

// ─── Powertrain (engine, gearbox, energy) ──────────────────────────

@immutable
class PowertrainGate {
  const PowertrainGate({
    // Battery + range
    this.batteryPct,
    this.fuelPct,
    this.rangeEvKm,
    this.rangeFuelKm,
    this.batteryRemainingWh,
    // Energy mode
    this.evMode,
    this.hevMode,
    this.energyState,
    this.regenPower,
    // Engine / motors
    this.engineSpeed,
    this.engineSpeedGb,
    this.enginePower,
    this.frontMotorSpeed,
    this.rearMotorSpeed,
    this.frontMotorTorque,
    this.rearMotorTorque,
    this.engineDisplacement,
    this.voiceSimulator,
    this.simulatorSourceType,
    // Gearbox
    this.gearboxType,
    this.gearboxAutoMode,
    this.gearboxManualLevel,
    this.epbState,
    this.parkBrakeSwitch,
    // Coolant
    this.waterTempC,
  });

  final int? batteryPct; // raw: battery_pct        ✅
  final int? fuelPct; // raw: fuel_pct           ❓
  final int? rangeEvKm; // raw: range_ev_km        ✅
  final int? rangeFuelKm; // raw: range_fuel_km      ✅
  final int? batteryRemainingWh; // raw: battery_wh         ❓
  final int? evMode; // raw: ev_mode            ✅
  final int? hevMode; // raw: hev_mode           ✅
  final int? energyState; // raw: energy_state       ❓
  final int? regenPower; // raw: regen_power        ❓
  final int? engineSpeed; // raw: engine_rpm         ❓
  final int? engineSpeedGb; // raw: engine_rpm_gb      ❓
  final int? enginePower; // raw: engine_power       ❓
  final int? frontMotorSpeed; // raw: motor_f_rpm        ❓
  final int? rearMotorSpeed; // raw: motor_r_rpm        ❓
  final int? frontMotorTorque; // raw: motor_f_torque     ❓
  final int? rearMotorTorque; // raw: motor_r_torque     ❓
  final int? engineDisplacement; // raw: engine_disp        ❓
  final int? voiceSimulator; // raw: voice_sim          ❓
  final int? simulatorSourceType; // raw: voice_sim_source   ❓
  final int? gearboxType; // raw: gearbox_type       ❓
  final int? gearboxAutoMode; // raw: gear_auto_mode     ❓
  final int? gearboxManualLevel; // raw: gear_manual        ❓
  final int? epbState; // raw: epb_state          ❓
  final int? parkBrakeSwitch; // raw: park_brake         ❓
  final int? waterTempC; // raw: water_temp         ❓

  static PowertrainGate fromRaw(Map<String, dynamic> raw) {
    int? r(String k) => raw[k] as int?;
    return PowertrainGate(
      batteryPct: r('battery_pct'),
      fuelPct: r('fuel_pct'),
      rangeEvKm: r('range_ev_km'),
      rangeFuelKm: r('range_fuel_km'),
      batteryRemainingWh: r('battery_wh'),
      evMode: r('ev_mode'),
      hevMode: r('hev_mode'),
      energyState: r('energy_state'),
      regenPower: r('regen_power'),
      engineSpeed: r('engine_rpm'),
      engineSpeedGb: r('engine_rpm_gb'),
      enginePower: r('engine_power'),
      frontMotorSpeed: r('motor_f_rpm'),
      rearMotorSpeed: r('motor_r_rpm'),
      frontMotorTorque: r('motor_f_torque'),
      rearMotorTorque: r('motor_r_torque'),
      engineDisplacement: r('engine_disp'),
      voiceSimulator: r('voice_sim'),
      simulatorSourceType: r('voice_sim_source'),
      gearboxType: r('gearbox_type'),
      gearboxAutoMode: r('gear_auto_mode'),
      gearboxManualLevel: r('gear_manual'),
      epbState: r('epb_state'),
      parkBrakeSwitch: r('park_brake'),
      waterTempC: r('water_temp'),
    );
  }
}

// ─── Charging (EV) ─────────────────────────────────────────────────

@immutable
class ChargingGate {
  const ChargingGate({
    this.capStateAc,
    this.capStateDc,
    this.capacityKwh,
    this.powerKw,
    this.workState,
    this.fullRestHour,
    this.fullRestMinute,
    this.socSaveSwitch,
    this.targetSoc,
    this.energyFeedback,
    this.wirelessFitted,
    this.wirelessSwitch,
  });

  final int? capStateAc; // raw: chg_cap_ac           ❓
  final int? capStateDc; // raw: chg_cap_dc           ❓
  final int? capacityKwh; // raw: chg_capacity         ❓
  final int? powerKw; // raw: chg_power            ❓
  final int? workState; // raw: chg_work_state       ❓
  final int? fullRestHour; // raw: chg_eta_h            ❓
  final int? fullRestMinute; // raw: chg_eta_m            ❓
  final int? socSaveSwitch; // raw: chg_soc_save         ❓
  final int? targetSoc; // raw: chg_target_soc       ❓
  final int? energyFeedback; // raw: chg_energy_fb        ❓
  final int? wirelessFitted; // raw: chg_wireless_fitted  ❓
  final int? wirelessSwitch; // raw: chg_wireless_on      ❓

  static ChargingGate fromRaw(Map<String, dynamic> raw) {
    int? r(String k) => raw[k] as int?;
    return ChargingGate(
      capStateAc: r('chg_cap_ac'),
      capStateDc: r('chg_cap_dc'),
      capacityKwh: r('chg_capacity'),
      powerKw: r('chg_power'),
      workState: r('chg_work_state'),
      fullRestHour: r('chg_eta_h'),
      fullRestMinute: r('chg_eta_m'),
      socSaveSwitch: r('chg_soc_save'),
      targetSoc: r('chg_target_soc'),
      energyFeedback: r('chg_energy_fb'),
      wirelessFitted: r('chg_wireless_fitted'),
      wirelessSwitch: r('chg_wireless_on'),
    );
  }
}

// ─── Seats (heat / vent / belt) ────────────────────────────────────

@immutable
class SeatsGate {
  const SeatsGate({
    this.heatDrv,
    this.heatPass,
    this.heatRl,
    this.heatRr,
    this.ventDrv,
    this.ventPass,
    this.ventRl,
    this.ventRr,
    this.beltMain,
    this.beltDeputy,
    this.beltRowL,
    this.beltRowMid,
    this.beltRowR,
  });

  final int? heatDrv; // raw: seat_heat_drv     🟡 (we write)
  final int? heatPass; // raw: seat_heat_pass    🟡
  final int? heatRl; // raw: seat_heat_rl      🟡
  final int? heatRr; // raw: seat_heat_rr      🟡
  final int? ventDrv; // raw: seat_vent_drv     🟡
  final int? ventPass; // raw: seat_vent_pass    🟡
  final int? ventRl; // raw: seat_vent_rl      🟡
  final int? ventRr; // raw: seat_vent_rr      🟡
  final int? beltMain; // raw: belt_main         ❓
  final int? beltDeputy; // raw: belt_deputy       ❓
  final int? beltRowL; // raw: belt_row_l        ❓
  final int? beltRowMid; // raw: belt_row_mid      ❓
  final int? beltRowR; // raw: belt_row_r        ❓

  static SeatsGate fromRaw(Map<String, dynamic> raw) {
    int? r(String k) => raw[k] as int?;
    return SeatsGate(
      heatDrv: r('seat_heat_drv'),
      heatPass: r('seat_heat_pass'),
      heatRl: r('seat_heat_rl'),
      heatRr: r('seat_heat_rr'),
      ventDrv: r('seat_vent_drv'),
      ventPass: r('seat_vent_pass'),
      ventRl: r('seat_vent_rl'),
      ventRr: r('seat_vent_rr'),
      beltMain: r('belt_main'),
      beltDeputy: r('belt_deputy'),
      beltRowL: r('belt_row_l'),
      beltRowMid: r('belt_row_mid'),
      beltRowR: r('belt_row_r'),
    );
  }
}

// ─── Tires (TPMS) ──────────────────────────────────────────────────

@immutable
class TiresGate {
  const TiresGate({
    this.pressureLf,
    this.pressureRf,
    this.pressureLr,
    this.pressureRr,
    this.tempLf,
    this.tempRf,
    this.tempLr,
    this.tempRr,
  });

  final int? pressureLf; // raw: tpms_pressure_lf  ❓
  final int? pressureRf; // raw: tpms_pressure_rf  ❓
  final int? pressureLr; // raw: tpms_pressure_lr  ❓
  final int? pressureRr; // raw: tpms_pressure_rr  ❓
  final int? tempLf; // raw: tpms_temp_lf      ❓
  final int? tempRf; // raw: tpms_temp_rf      ❓
  final int? tempLr; // raw: tpms_temp_lr      ❓
  final int? tempRr; // raw: tpms_temp_rr      ❓

  static TiresGate fromRaw(Map<String, dynamic> raw) {
    int? r(String k) => raw[k] as int?;
    return TiresGate(
      pressureLf: r('tpms_pressure_lf'),
      pressureRf: r('tpms_pressure_rf'),
      pressureLr: r('tpms_pressure_lr'),
      pressureRr: r('tpms_pressure_rr'),
      tempLf: r('tpms_temp_lf'),
      tempRf: r('tpms_temp_rf'),
      tempLr: r('tpms_temp_lr'),
      tempRr: r('tpms_temp_rr'),
    );
  }
}

// ─── Radar (parking sensors) ───────────────────────────────────────

@immutable
class RadarGate {
  const RadarGate({
    this.distLeft,
    this.distRight,
    this.distLeftFront,
    this.distRightFront,
    this.distLeftRear,
    this.distRightRear,
    this.distFrontLeftMid,
    this.distFrontRightMid,
    this.midRangeDist,
    this.midRangeStatus,
    this.reverseSwitch,
  });

  final int? distLeft; // raw: radar_l        ❓
  final int? distRight; // raw: radar_r        ❓
  final int? distLeftFront; // raw: radar_lf       ❓
  final int? distRightFront; // raw: radar_rf       ❓
  final int? distLeftRear; // raw: radar_lr       ❓
  final int? distRightRear; // raw: radar_rr       ❓
  final int? distFrontLeftMid; // raw: radar_flm      ❓
  final int? distFrontRightMid; // raw: radar_frm      ❓
  final int? midRangeDist; // raw: radar_mr_dist  ❓
  final int? midRangeStatus; // raw: radar_mr_state ❓
  final int? reverseSwitch; // raw: radar_rev_sw   ❓

  static RadarGate fromRaw(Map<String, dynamic> raw) {
    int? r(String k) => raw[k] as int?;
    return RadarGate(
      distLeft: r('radar_l'),
      distRight: r('radar_r'),
      distLeftFront: r('radar_lf'),
      distRightFront: r('radar_rf'),
      distLeftRear: r('radar_lr'),
      distRightRear: r('radar_rr'),
      distFrontLeftMid: r('radar_flm'),
      distFrontRightMid: r('radar_frm'),
      midRangeDist: r('radar_mr_dist'),
      midRangeStatus: r('radar_mr_state'),
      reverseSwitch: r('radar_rev_sw'),
    );
  }
}

// ─── Comfort (massage / atmos / wipers / fragrance) ────────────────

@immutable
class ComfortGate {
  const ComfortGate({
    this.massageDrvMode,
    this.massageDrvLevel,
    this.massageCoMode,
    this.massageCoLevel,
    this.atmosColor,
    this.atmosBrightness,
    this.atmosFrontColor,
    this.atmosFrontBrightness,
    this.atmosBackColor,
    this.atmosBackBrightness,
    this.fragOn,
    this.fragScent,
    this.fragLevel,
    this.wiperFrontLevel,
    this.wiperFrontState,
    this.wiperRearState,
    this.wiperRelay,
    this.wiperFrontMaintenance,
    this.wiperRearMaintenance,
    this.insideLightDoor,
    this.insideLightMaster,
  });

  final int? massageDrvMode; // raw: massage_drv_mode    🟡
  final int? massageDrvLevel; // raw: massage_drv_level   🟡
  final int? massageCoMode; // raw: massage_co_mode     🟡
  final int? massageCoLevel; // raw: massage_co_level    🟡
  final int? atmosColor; // raw: atmos_color         🟡
  final int? atmosBrightness; // raw: atmos_bright        🟡
  final int? atmosFrontColor; // raw: atmos_front_color   ❓
  final int? atmosFrontBrightness; // raw: atmos_front_bright  ❓
  final int? atmosBackColor; // raw: atmos_back_color    ❓
  final int? atmosBackBrightness; // raw: atmos_back_bright   ❓
  final int? fragOn; // raw: frag_on             🟡
  final int? fragScent; // raw: frag_scent          🟡
  final int? fragLevel; // raw: frag_level          🟡
  final int? wiperFrontLevel; // raw: wiper_f_level       ❓
  final int? wiperFrontState; // raw: wiper_f_state       ❓
  final int? wiperRearState; // raw: wiper_r_state       ❓
  final int? wiperRelay; // raw: wiper_relay         ❓
  final int? wiperFrontMaintenance; // raw: wiper_f_maint       ❓
  final int? wiperRearMaintenance; // raw: wiper_r_maint       ❓
  final int? insideLightDoor; // raw: inside_light_door   ❓
  final int? insideLightMaster; // raw: inside_light        ❓

  static ComfortGate fromRaw(Map<String, dynamic> raw) {
    int? r(String k) => raw[k] as int?;
    return ComfortGate(
      massageDrvMode: r('massage_drv_mode'),
      massageDrvLevel: r('massage_drv_level'),
      massageCoMode: r('massage_co_mode'),
      massageCoLevel: r('massage_co_level'),
      atmosColor: r('atmos_color'),
      atmosBrightness: r('atmos_bright'),
      atmosFrontColor: r('atmos_front_color'),
      atmosFrontBrightness: r('atmos_front_bright'),
      atmosBackColor: r('atmos_back_color'),
      atmosBackBrightness: r('atmos_back_bright'),
      fragOn: r('frag_on'),
      fragScent: r('frag_scent'),
      fragLevel: r('frag_level'),
      wiperFrontLevel: r('wiper_f_level'),
      wiperFrontState: r('wiper_f_state'),
      wiperRearState: r('wiper_r_state'),
      wiperRelay: r('wiper_relay'),
      wiperFrontMaintenance: r('wiper_f_maint'),
      wiperRearMaintenance: r('wiper_r_maint'),
      insideLightDoor: r('inside_light_door'),
      insideLightMaster: r('inside_light'),
    );
  }
}

// ─── Sensors (cabin environmental) ─────────────────────────────────

@immutable
class SensorsGate {
  const SensorsGate({
    this.cabinTempRaw,
    this.cabinHumidity,
    this.cabinLight,
    this.slope,
    this.pm25In,
    this.pm25Out,
    this.pm25Online,
  });

  final int? cabinTempRaw; // raw: sensor_temp        ❓
  final int? cabinHumidity; // raw: sensor_humidity    ❓
  final int? cabinLight; // raw: sensor_light       ❓
  final int? slope; // raw: sensor_slope       ❓
  final int? pm25In; // raw: pm25_in            ❓
  final int? pm25Out; // raw: pm25_out           ❓
  final int? pm25Online; // raw: pm25_online        ❓

  static SensorsGate fromRaw(Map<String, dynamic> raw) {
    int? r(String k) => raw[k] as int?;
    return SensorsGate(
      cabinTempRaw: r('sensor_temp'),
      cabinHumidity: r('sensor_humidity'),
      cabinLight: r('sensor_light'),
      slope: r('sensor_slope'),
      pm25In: r('pm25_in'),
      pm25Out: r('pm25_out'),
      pm25Online: r('pm25_online'),
    );
  }
}

// ─── Dynamics (vehicle motion) ─────────────────────────────────────

@immutable
class DynamicsGate {
  const DynamicsGate({
    this.speedKmh,
    this.acceleratorPct,
    this.brakePct,
    this.cruiseSetSpeed,
    this.avhState,
  });

  final int? speedKmh; // raw: speed_kmh         ✅
  final int? acceleratorPct; // raw: accelerator_pct   ❓
  final int? brakePct; // raw: brake_pct         ❓
  final int? cruiseSetSpeed; // raw: cruise_set_speed  ❓
  final int? avhState; // raw: avh_state         ❓

  static DynamicsGate fromRaw(Map<String, dynamic> raw) {
    int? r(String k) => raw[k] as int?;
    return DynamicsGate(
      speedKmh: r('speed_kmh'),
      acceleratorPct: r('accelerator_pct'),
      brakePct: r('brake_pct'),
      cruiseSetSpeed: r('cruise_set_speed'),
      avhState: r('avh_state'),
    );
  }
}

// ─── Statistics (rolling trip stats) ───────────────────────────────

@immutable
class StatisticsGate {
  const StatisticsGate({
    this.totalMileageKm,
    this.evMileageKm,
    this.hevMileageKm,
    this.totalElecKwh,
    this.totalFuelL,
    this.totalElecConPHM,
    this.totalFuelConPHM,
    this.lastElecConPHM,
    this.lastFuelConPHM,
    this.instantElecCon,
    this.instantFuelCon,
    this.batteryHealthPct,
    this.batteryAvgTempC,
    this.batteryMaxTempC,
    this.batteryMinTempC,
    this.batteryMaxV,
    this.batteryMinV,
  });

  final int? totalMileageKm; // raw: stat_total_km           ❓
  final int? evMileageKm; // raw: stat_ev_km              ❓
  final int? hevMileageKm; // raw: stat_hev_km             ❓
  final int? totalElecKwh; // raw: stat_total_elec_kwh     ❓
  final int? totalFuelL; // raw: stat_total_fuel_l       ❓
  final int? totalElecConPHM; // raw: stat_total_elec_phm     ❓
  final int? totalFuelConPHM; // raw: stat_total_fuel_phm     ❓
  final int? lastElecConPHM; // raw: stat_last_elec_phm      ❓
  final int? lastFuelConPHM; // raw: stat_last_fuel_phm      ❓
  final int? instantElecCon; // raw: stat_instant_elec       ❓
  final int? instantFuelCon; // raw: stat_instant_fuel       ❓
  final int? batteryHealthPct; // raw: stat_battery_health     ❓
  final int? batteryAvgTempC; // raw: stat_battery_avg_temp   ❓
  final int? batteryMaxTempC; // raw: stat_battery_max_temp   ❓
  final int? batteryMinTempC; // raw: stat_battery_min_temp   ❓
  final int? batteryMaxV; // raw: stat_battery_max_v      ❓
  final int? batteryMinV; // raw: stat_battery_min_v      ❓

  static StatisticsGate fromRaw(Map<String, dynamic> raw) {
    int? r(String k) => raw[k] as int?;
    return StatisticsGate(
      totalMileageKm: r('stat_total_km'),
      evMileageKm: r('stat_ev_km'),
      hevMileageKm: r('stat_hev_km'),
      totalElecKwh: r('stat_total_elec_kwh'),
      totalFuelL: r('stat_total_fuel_l'),
      totalElecConPHM: r('stat_total_elec_phm'),
      totalFuelConPHM: r('stat_total_fuel_phm'),
      lastElecConPHM: r('stat_last_elec_phm'),
      lastFuelConPHM: r('stat_last_fuel_phm'),
      instantElecCon: r('stat_instant_elec'),
      instantFuelCon: r('stat_instant_fuel'),
      batteryHealthPct: r('stat_battery_health'),
      batteryAvgTempC: r('stat_battery_avg_temp'),
      batteryMaxTempC: r('stat_battery_max_temp'),
      batteryMinTempC: r('stat_battery_min_temp'),
      batteryMaxV: r('stat_battery_max_v'),
      batteryMinV: r('stat_battery_min_v'),
    );
  }
}

// ─── Aggregate ─────────────────────────────────────────────────────

/// Aggregate of every car-data sub-gate. Construct from a single
/// [readStatus] map; each sub-gate parses its own keys.
@immutable
class CarGate {
  const CarGate({
    required this.connection,
    required this.closures,
    required this.climate,
    required this.lights,
    required this.powertrain,
    required this.charging,
    required this.seats,
    required this.tires,
    required this.radar,
    required this.comfort,
    required this.sensors,
    required this.dynamics,
    required this.statistics,
    this.fieldAges = const {},
  });

  final ConnectionGate connection;
  final ClosuresGate closures;
  final ClimateGate climate;
  final LightsGate lights;
  final PowertrainGate powertrain;
  final ChargingGate charging;
  final SeatsGate seats;
  final TiresGate tires;
  final RadarGate radar;
  final ComfortGate comfort;
  final SensorsGate sensors;
  final DynamicsGate dynamics;
  final StatisticsGate statistics;

  /// Per-key staleness (`Duration` since last fresh read), populated
  /// from `__field_age_ms` if the host produces it. Empty otherwise.
  final Map<String, Duration> fieldAges;

  static const empty = CarGate(
    connection: ConnectionGate(),
    closures: ClosuresGate(),
    climate: ClimateGate(),
    lights: LightsGate(),
    powertrain: PowertrainGate(),
    charging: ChargingGate(),
    seats: SeatsGate(),
    tires: TiresGate(),
    radar: RadarGate(),
    comfort: ComfortGate(),
    sensors: SensorsGate(),
    dynamics: DynamicsGate(),
    statistics: StatisticsGate(),
  );

  static CarGate fromRaw(Map<String, dynamic> raw) {
    return CarGate(
      connection: ConnectionGate.fromRaw(raw),
      closures: ClosuresGate.fromRaw(raw),
      climate: ClimateGate.fromRaw(raw),
      lights: LightsGate.fromRaw(raw),
      powertrain: PowertrainGate.fromRaw(raw),
      charging: ChargingGate.fromRaw(raw),
      seats: SeatsGate.fromRaw(raw),
      tires: TiresGate.fromRaw(raw),
      radar: RadarGate.fromRaw(raw),
      comfort: ComfortGate.fromRaw(raw),
      sensors: SensorsGate.fromRaw(raw),
      dynamics: DynamicsGate.fromRaw(raw),
      statistics: StatisticsGate.fromRaw(raw),
      fieldAges: _parseFieldAges(raw['__field_age_ms']),
    );
  }

  /// Flat camelCase shape used by the voice tool's `car_status`
  /// response (the LLM's tool schema is wide — it expects every field
  /// the car knows about so it can answer arbitrary questions like
  /// "what fan level is the AC on?"). Nulls are dropped so the LLM
  /// only sees fields the car actually reports. Wire-key style here
  /// is camelCase (matches the LLM's tool definition); the snake_case
  /// MQTT shape is built separately in [StatusPublisher._shape].
  Map<String, dynamic> toFlatJson() => <String, dynamic>{
    'adbConnected': connection.adbConnected,
    'daemonReady': connection.daemonReady,
    if (closures.doorLock != null) 'doorLock': closures.doorLock,
    if (closures.doorLf != null) 'doorLf': closures.doorLf,
    if (closures.doorRf != null) 'doorRf': closures.doorRf,
    if (closures.doorLr != null) 'doorLr': closures.doorLr,
    if (closures.doorRr != null) 'doorRr': closures.doorRr,
    if (closures.trunk != null) 'trunk': closures.trunk,
    if (climate.acPower != null) 'acPower': climate.acPower,
    if (climate.fanLevel != null) 'fanLevel': climate.fanLevel,
    if (climate.windMode != null) 'windMode': climate.windMode,
    if (climate.cycleMode != null) 'cycleMode': climate.cycleMode,
    if (climate.targetTempC != null) 'targetTempC': climate.targetTempC,
    if (climate.cabinTempC != null) 'cabinTempC': climate.cabinTempC,
    if (climate.outsideTempC != null) 'outsideTempC': climate.outsideTempC,
    if (lights.headlight != null) 'headlight': lights.headlight,
    if (lights.lowBeam != null) 'lowBeam': lights.lowBeam,
    if (lights.highBeam != null) 'highBeam': lights.highBeam,
    if (lights.frontFog != null) 'frontFog': lights.frontFog,
    if (lights.rearFog != null) 'rearFog': lights.rearFog,
    if (powertrain.batteryPct != null) 'batteryPct': powertrain.batteryPct,
    if (powertrain.rangeEvKm != null) 'rangeEvKm': powertrain.rangeEvKm,
    if (powertrain.rangeFuelKm != null) 'rangeFuelKm': powertrain.rangeFuelKm,
    if (powertrain.evMode != null) 'evMode': powertrain.evMode,
    if (powertrain.hevMode != null) 'hevMode': powertrain.hevMode,
    if (dynamics.speedKmh != null) 'speedKmh': dynamics.speedKmh,
    if (connection.lastPushAt != null)
      'lastPushAt': connection.lastPushAt!.toIso8601String(),
  };

  static Map<String, Duration> _parseFieldAges(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, Duration>{};
    raw.forEach((k, v) {
      if (k is! String) return;
      final ms = (v is num) ? v.toInt() : null;
      if (ms == null || ms < 0) return;
      out[k] = Duration(milliseconds: ms);
    });
    return out;
  }
}

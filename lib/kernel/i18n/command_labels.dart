import 'generated/app_localizations.dart';

// Single source of truth mapping `CarCommand.id` → a translated label.
// Every surface that renders commands (QuickActionsGrid, FeatureRail,
// dev/Compat tile, future tunnel-side debug screens) resolves labels
// through `localizedCommandLabel` rather than the raw `CarCommand.label`
// string defined in `command_registry.dart`.
//
// The canonical id (`door.lock`, `hood.close`, …) stays unchanged on the
// wire and in compat report JSON — only the displayed label flows through
// here. Unknown ids fall through to null so callers can keep the raw
// `CarCommand.label` as a fallback while a translation lands.
String? localizedCommandLabel(S t, String commandId) => switch (commandId) {
  // Doors
  'door.lock' => t.cmdDoorLock,
  'door.unlock' => t.cmdDoorUnlock,
  'door.trunk.open' => t.cmdDoorTrunkOpen,
  'door.trunk.close' => t.cmdDoorTrunkClose,
  'hood.open' => t.cmdHoodOpen,
  'hood.close' => t.cmdHoodClose,
  'hood.stop' => t.cmdHoodStop,

  // Climate
  'climate.power' => t.cmdClimatePower,
  'climate.temp' => t.cmdClimateTemp,
  'climate.fan' => t.cmdClimateFan,
  'climate.mode' => t.cmdClimateMode,
  'climate.cycle' => t.cmdClimateCycle,
  'climate.defrost_f' => t.cmdClimateDefrostF,
  'climate.defrost_r' => t.cmdClimateDefrostR,
  'climate.compressor' => t.cmdClimateCompressor,
  'climate.max_hot' => t.cmdClimateMaxHot,
  'climate.max_cool' => t.cmdClimateMaxCool,
  'climate.comfort_mode' => t.cmdClimateComfortMode,
  'climate.rear_lock' => t.cmdClimateRearLock,

  // Comfort
  'comfort.massage' => t.cmdComfortMassage,
  'comfort.frag.on' => t.cmdComfortFragOn,
  'comfort.frag.off' => t.cmdComfortFragOff,
  'comfort.atmos' => t.cmdComfortAtmos,

  // Windows + sunroof
  'window.fl.open' => t.cmdWindowFlOpen,
  'window.fl.close' => t.cmdWindowFlClose,
  'window.fl.stop' => t.cmdWindowFlStop,
  'window.fl.down' => t.cmdWindowFlDown,
  'window.fr.open' => t.cmdWindowFrOpen,
  'window.fr.close' => t.cmdWindowFrClose,
  'window.fr.stop' => t.cmdWindowFrStop,
  'window.rl.open' => t.cmdWindowRlOpen,
  'window.rl.close' => t.cmdWindowRlClose,
  'window.rl.stop' => t.cmdWindowRlStop,
  'window.rr.open' => t.cmdWindowRrOpen,
  'window.rr.close' => t.cmdWindowRrClose,
  'window.rr.stop' => t.cmdWindowRrStop,
  'window.all.open' => t.cmdWindowAllOpen,
  'window.all.close' => t.cmdWindowAllClose,
  'sunroof.open' => t.cmdSunroofOpen,
  'sunroof.close' => t.cmdSunroofClose,
  'sunroof.tilt' => t.cmdSunroofTilt,
  'sunroof.stop' => t.cmdSunroofStop,

  // Seats
  'seat.heat.drv' => t.cmdSeatHeatDrv,
  'seat.heat.pass' => t.cmdSeatHeatPass,
  'seat.heat.rl' => t.cmdSeatHeatRl,
  'seat.heat.rr' => t.cmdSeatHeatRr,
  'seat.vent.drv' => t.cmdSeatVentDrv,
  'seat.vent.pass' => t.cmdSeatVentPass,
  'seat.vent.rl' => t.cmdSeatVentRl,
  'seat.vent.rr' => t.cmdSeatVentRr,

  // Lights
  'light.head' => t.cmdLightHead,
  'light.head.on' => t.cmdLightHeadOn,
  'light.head.off' => t.cmdLightHeadOff,
  'light.fog_f' => t.cmdLightFogF,
  'light.fog_r' => t.cmdLightFogR,
  'light.turn_left' => t.cmdLightTurnLeft,
  'light.turn_right' => t.cmdLightTurnRight,
  'light.flash' => t.cmdLightFlash,
  'light.find_car' => t.cmdLightFindCar,

  // Radio
  'radio.play_by_name' => t.cmdRadioPlayByName,
  'radio.play_station' => t.cmdRadioPlayStation,
  'radio.pause' => t.cmdRadioPause,
  'radio.resume' => t.cmdRadioResume,
  'radio.stop' => t.cmdRadioStop,
  'radio.next_fav' => t.cmdRadioNextFav,

  // Status
  'car.status' => t.cmdCarStatus,

  _ => null,
};

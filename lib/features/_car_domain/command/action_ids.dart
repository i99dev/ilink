/// Single source of truth for every action id that crosses the Dart↔Kotlin
/// boundary. Controllers must reference these constants — never bare
/// strings — so a rename is one edit on each side and drift is caught by
/// the contract test (`test/features/_car_domain/command/action_ids_contract_test.dart`)
/// which reads the Kotlin mirror file (`ActionIds.kt`) and asserts parity.
///
/// Mirror: `android/app/src/main/kotlin/com/i99dev/ilink/car/ActionIds.kt`.
/// Any change here must be matched there (or the contract test will fail).
///
/// These constants mirror the canonical native table IDs. Registry commands
/// either dispatch their id directly or resolve to one of these atomic actions.
class ActionIds {
  ActionIds._();

  // ── Doors / trunk / hood ────────────────────────────────────────────
  static const String doorLock = 'door.lock';
  static const String doorUnlock = 'door.unlock';
  static const String trunkOpen = 'door.trunk.open';
  static const String trunkClose = 'door.trunk.close';
  // Hood share a single wire key (BODY 0x4C110020), value 1=open / 3=close / 2=stop.
  static const String hoodOpen = 'hood.open';
  static const String hoodClose = 'hood.close';
  static const String hoodStop = 'hood.stop';

  // ── Windows (0=stop, 1=open, 2=close, 3=full-down) ──────────────────
  // Wire value preserves a historical fr/rf mismatch on the Kotlin side:
  // `window.rf` is the *front-right* key. Constant name makes it explicit.
  static const String windowFrontLeft = 'window.fl';
  static const String windowFrontRight = 'window.rf';
  static const String windowRearLeft = 'window.rl';
  static const String windowRearRight = 'window.rr';

  // ── Sunroof ─────────────────────────────────────────────────────────
  static const String sunroofCtl = 'sunroof.ctl';
  static const String sunroofPercent = 'sunroof.percent';

  // ── Climate ─────────────────────────────────────────────────────────
  static const String acPower = 'climate.power';
  static const String acFan = 'climate.fan';
  static const String acTemp = 'climate.temp';
  static const String acMode = 'climate.mode';
  static const String acCycle = 'climate.cycle';
  static const String acDefrostFront = 'climate.defrost_f';
  static const String acDefrostRear = 'climate.defrost_r';
  static const String acCompressor = 'climate.compressor';
  static const String acMaxHot = 'climate.max_hot';
  static const String acMaxCool = 'climate.max_cool';

  // ── Massage (only drv/co are wired on Kotlin) ───────────────────────
  static const String massageDrvMode = 'massage.drv.mode';
  static const String massageDrvLevel = 'massage.drv.level';
  static const String massageCoMode = 'massage.co.mode';
  static const String massageCoLevel = 'massage.co.level';

  // ── Exterior lights ─────────────────────────────────────────────────
  static const String lightHead = 'light.head';
  static const String lightHeadOn = 'light.head.on';
  static const String lightHeadOff = 'light.head.off';
  static const String lightFogFront = 'light.fog_f';
  static const String lightFogRear = 'light.fog_r';
  static const String lightTurnLeft = 'light.turn_left';
  static const String lightTurnRight = 'light.turn_right';
  static const String lightFlash = 'light.flash';
  static const String lightFindCar = 'light.find_car';

  // ── Ambient (atmos) + fragrance — slow UNIT path ────────────────────
  static const String atmosOn = 'comfort.atmos.on';
  static const String atmosOff = 'comfort.atmos.off';
  static const String atmosBright = 'comfort.atmos.bright';
  static const String atmosColor = 'comfort.atmos.color';
  static const String fragOn = 'comfort.frag.on';
  static const String fragOff = 'comfort.frag.off';
  static const String fragSelect = 'frag.select';
  static const String fragStatus = 'frag.status';

  // ── Seat heat / vent (slow UNIT path) ───────────────────────────────
  static const String heatDrvLevel = 'seat.heat.drv';
  static const String heatPassLevel = 'seat.heat.pass';
  static const String heatRearLeftLevel = 'seat.heat.rl';
  static const String heatRearRightLevel = 'seat.heat.rr';
  static const String ventDrvLevel = 'seat.vent.drv';

  /// Every action id known to the Kotlin dispatcher. A controller method
  /// must only ever produce ids in this set; the contract test enforces it.
  static const Set<String> all = {
    doorLock,
    doorUnlock,
    trunkOpen,
    trunkClose,
    hoodOpen,
    hoodClose,
    hoodStop,
    windowFrontLeft,
    windowFrontRight,
    windowRearLeft,
    windowRearRight,
    sunroofCtl,
    sunroofPercent,
    acPower,
    acFan,
    acTemp,
    acMode,
    acCycle,
    acDefrostFront,
    acDefrostRear,
    acCompressor,
    acMaxHot,
    acMaxCool,
    massageDrvMode,
    massageDrvLevel,
    massageCoMode,
    massageCoLevel,
    lightHead,
    lightHeadOn,
    lightHeadOff,
    lightFogFront,
    lightFogRear,
    lightTurnLeft,
    lightTurnRight,
    lightFlash,
    lightFindCar,
    atmosOn,
    atmosOff,
    atmosBright,
    atmosColor,
    fragOn,
    fragOff,
    fragSelect,
    fragStatus,
    heatDrvLevel,
    heatPassLevel,
    heatRearLeftLevel,
    heatRearRightLevel,
    ventDrvLevel,
  };

  /// Templated id for massage. Only `drv`/`co` are wired on Kotlin today;
  /// `rl`/`rr` would return `unknown action` at runtime — caller should
  /// guard or accept the failure. Returns null for unsupported seat/field.
  static String? massage(String seat, String field) {
    switch ('$seat.$field') {
      case 'drv.mode':
        return massageDrvMode;
      case 'drv.level':
        return massageDrvLevel;
      case 'co.mode':
        return massageCoMode;
      case 'co.level':
        return massageCoLevel;
      default:
        return null;
    }
  }

  /// Templated id for ambient lighting (`atmos.<field>`). Returns null for
  /// fields the Kotlin UNIT dispatcher doesn't recognise.
  static String? atmos(String field) {
    switch (field) {
      case 'on':
        return atmosOn;
      case 'off':
        return atmosOff;
      case 'bright':
        return atmosBright;
      case 'color':
        return atmosColor;
      default:
        return null;
    }
  }

  /// Templated id for seat heat. `drv|pass|rl|rr` — all four are wired
  /// on Kotlin UNIT path (unlike massage).
  static String? seatHeat(String seat) {
    switch (seat) {
      case 'drv':
        return heatDrvLevel;
      case 'pass':
        return heatPassLevel;
      case 'rl':
        return heatRearLeftLevel;
      case 'rr':
        return heatRearRightLevel;
      default:
        return null;
    }
  }
}

package com.i99dev.ilink.car

/**
 * Mirror of `dash/lib/core/car/commands/action_ids.dart`. The Dart contract
 * test reads this file as text and asserts parity with the Dart constants,
 * so renames/additions must happen on both sides in the same change.
 *
 * Do NOT introduce derived strings; every id is a literal const val so the
 * parser in `test/core/car/commands/action_ids_contract_test.dart` can
 * pick them up with a single regex.
 */
object ActionIds {
    // Doors / trunk / hood (hood shares BODY 0x4C110020; 1=open, 3=close, 2=stop)
    const val doorLock = "door.lock"
    const val doorUnlock = "door.unlock"
    const val trunkOpen = "door.trunk.open"
    const val trunkClose = "door.trunk.close"
    const val hoodOpen = "hood.open"
    const val hoodClose = "hood.close"
    const val hoodStop = "hood.stop"

    // Windows (0=stop, 1=open, 2=close, 3=full-down)
    const val windowFrontLeft = "window.fl"
    const val windowFrontRight = "window.rf"
    const val windowRearLeft = "window.rl"
    const val windowRearRight = "window.rr"

    // Sunroof
    const val sunroofCtl = "sunroof.ctl"
    const val sunroofPercent = "sunroof.percent"

    // Climate
    const val acPower = "climate.power"
    const val acFan = "climate.fan"
    const val acTemp = "climate.temp"
    const val acMode = "climate.mode"
    const val acCycle = "climate.cycle"
    const val acDefrostFront = "climate.defrost_f"
    const val acDefrostRear = "climate.defrost_r"
    const val acCompressor = "climate.compressor"
    const val acMaxHot = "climate.max_hot"
    const val acMaxCool = "climate.max_cool"

    // Massage (only drv/co wired on Kotlin)
    const val massageDrvMode = "massage.drv.mode"
    const val massageDrvLevel = "massage.drv.level"
    const val massageCoMode = "massage.co.mode"
    const val massageCoLevel = "massage.co.level"

    // Exterior lights
    const val lightHead = "light.head"
    const val lightHeadOn = "light.head.on"
    const val lightHeadOff = "light.head.off"
    const val lightFogFront = "light.fog_f"
    const val lightFogRear = "light.fog_r"
    const val lightTurnLeft = "light.turn_left"
    const val lightTurnRight = "light.turn_right"
    const val lightFlash = "light.flash"
    const val lightFindCar = "light.find_car"

    // Ambient + fragrance (UNIT path)
    const val atmosOn = "comfort.atmos.on"
    const val atmosOff = "comfort.atmos.off"
    const val atmosBright = "comfort.atmos.bright"
    const val atmosColor = "comfort.atmos.color"
    const val fragOn = "comfort.frag.on"
    const val fragOff = "comfort.frag.off"
    const val fragSelect = "frag.select"
    const val fragStatus = "frag.status"

    // Seat heat / vent (UNIT path)
    const val heatDrvLevel = "seat.heat.drv"
    const val heatPassLevel = "seat.heat.pass"
    const val heatRearLeftLevel = "seat.heat.rl"
    const val heatRearRightLevel = "seat.heat.rr"
    const val ventDrvLevel = "seat.vent.drv"
}

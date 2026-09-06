package com.i99dev.ilink.nav.transport

import com.i99dev.ilink.nav.logic.NavFormat
import com.i99dev.ilink.nav.logic.SomeIpGuideLine

/**
 * The production [HudRenderer] — wires the extracted, ground-truthed renderers:
 * cached maneuver PNGs ([ManeuverIconBitmaps]), the synthetic [SomeIpGuideLine],
 * and the [NavFormat] ETA. Replaces [NoopHudRenderer] in the live plugin.
 */
object DefaultHudRenderer : HudRenderer {
    override fun iconPng(maneuverCode: Int): ByteArray = ManeuverIconBitmaps.pngFor(maneuverCode)

    /** CAN-FID writes the raw maneuver code; the Amap transport maps separately. */
    override fun iconCode(maneuverCode: Int): Int = maneuverCode

    override fun guideLine(maneuverCode: Int, lat: Double?, lon: Double?, heading: Double?): String =
        SomeIpGuideLine.build(maneuverCode, lat, lon, heading)

    override fun formatEta(remainingSeconds: Int?): String =
        remainingSeconds?.takeIf { it >= 0 }?.let { NavFormat.time(it) } ?: ""
}

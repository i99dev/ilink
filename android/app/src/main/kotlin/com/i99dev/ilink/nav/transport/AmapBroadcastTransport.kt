package com.i99dev.ilink.nav.transport

import android.content.Context
import android.content.Intent
import com.i99dev.ilink.nav.NavHudOptions
import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.logic.ManeuverCatalog
import com.i99dev.ilink.nav.logic.NavFormat

/**
 * Additive sink — broadcasts `AUTONAVI_STANDARD_BROADCAST_SEND` so BYD's NATIVE
 * cluster (which expects Amap) renders the guidance. Verbatim from the reference's
 * `HudController.sendStandardAmapBroadcast`. Designed to run *alongside* the
 * primary transport (gated by a flag), not as the selected primary — so its
 * [isAvailable] is always true (it's fire-and-forget; no binding).
 */
class AmapBroadcastTransport(
    private val context: Context,
) : HudTransport {

    override val name: String = "AMAP_BROADCAST"

    override fun isAvailable(): Boolean = true

    override fun start() { /* stateless */ }

    override fun stop() = clear()

    override fun push(frame: NavGuidance, counter: Int) {
        // Self-gating: the controller fans every frame here unconditionally; this
        // channel only fires when the user has the Amap widget enabled.
        if (!NavHudOptions.amapWidget) return
        val i = Intent(ACTION).apply {
            putExtra("KEY_TYPE", 10001)
            putExtra("EXTRA_STATE", 8)
            putExtra("EXTRA_IS_FOREGROUND", 0)
            putExtra("IS_BYD_MAP", 1)
            putExtra("IS_BYD_BAIDU_MAP", 0)
            putExtra("TYPE", 8)
            putExtra("NEW_ICON", ManeuverCatalog.amapIcon(frame.maneuverIcon))
            frame.distanceMeters?.let {
                putExtra("SEG_REMAIN_DIS", it)
                putExtra("SEG_REMAIN_DIS_AUTO", NavFormat.distance(it))
            }
            putExtra("NEXT_ROAD_NAME", frame.roadName)
            frame.remainingDistanceMeters?.let {
                putExtra("ROUTE_REMAIN_DIS", it)
                putExtra("ROUTE_REMAIN_DIS_AUTO", NavFormat.distance(it))
            }
            frame.remainingTimeSeconds?.let {
                putExtra("ROUTE_REMAIN_TIME", it)
                putExtra("ROUTE_REMAIN_TIME_AUTO", NavFormat.time(it))
            }
            if (frame.secondaryRoadName.isNotBlank()) putExtra("NEXT_NEXT_ROAD_NAME", frame.secondaryRoadName)
        }
        context.sendBroadcast(i)
    }

    override fun clear() {
        val i = Intent(ACTION).apply {
            putExtra("KEY_TYPE", 10001)
            putExtra("TYPE", 9)
            putExtra("EXTRA_STATE", 1)
            putExtra("EXTRA_IS_FOREGROUND", 1)
            putExtra("IS_BYD_MAP", 1)
            putExtra("NEW_ICON", -1)
            putExtra("SEG_REMAIN_DIS", -1)
            putExtra("ROUTE_REMAIN_DIS", -1)
            putExtra("ROUTE_REMAIN_TIME", -1)
        }
        context.sendBroadcast(i)
    }

    companion object {
        private const val ACTION = "AUTONAVI_STANDARD_BROADCAST_SEND"
    }
}

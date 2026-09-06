package com.i99dev.ilink.nav.transport

import android.content.Context
import android.util.Log
import com.i99dev.ilink.adb.AdbShellBridge
import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.logic.ManeuverCatalog

/**
 * CAN-FID cluster-HUD output for **7.0UI** cars (Leopard 7 / Ti7). Those
 * clusters read navigation from the BYD instrument HAL
 * (`BYDAutoInstrumentDevice.set(INSTRUMENT_GUIDE_INFO_*, …)`), NOT the 5.0UI
 * SOME/IP RoadInfo service (dead on that ROM). Verified by decompiling
 * `com.byd.amapservice` + `com.byd.cluster`.
 *
 * The HAL is privileged (shell domain), so — exactly like the reference's `CarControl`
 * proxy — the writes run in the **persistent [DashDaemon][com.i99dev.ilink.helper.DashDaemon]**
 * (shell uid, holds the system Context + `BYDAutoInstrumentDevice` once). This
 * transport just streams one `halGuide` frame per push over the existing daemon
 * IPC — no per-frame `app_process` spawn, no per-frame `systemMain()`.
 *
 * Selected for **7.0UI** clusters, AND for Di5.1 **Huawei ADS HMI** clusters
 * (`com.huawei.hibaic.adshmiic` present — see [ClusterProtocol.isHuaweiHmiCluster]),
 * which are labelled 5.0UI but also read the instrument HAL and ignore SOME/IP.
 * Plain 5.0UI cars (B5/L8/L5/Di5.0, no Huawei HMI) stay on [SomeIpHudTransport] —
 * that path is untouched. The BYD HAL rejects our app uid, so the write MUST run
 * as shell uid via the daemon (the in-process reflected `set()` throws for us).
 */
class HalCanFidTransport(private val context: Context) : HudTransport {

    override val name: String = "CAN_FID"

    @Volatile private var lastWriteOk = false

    private val client get() = AdbShellBridge.daemonClient()

    /** True if this car's cluster is the Huawei ADS HMI variant, which renders
     *  from the instrument HAL (like 7.0UI) but is labelled 5.0UI. */
    private val huawei: Boolean get() = ClusterProtocol.isHuaweiHmiCluster(context)

    /** Available whenever the BYD instrument HAL is reachable — 7.0UI, Di5.1
     *  Huawei-HMI, AND any other trim that exposes `BYDAutoInstrumentDevice`
     *  (e.g. code40d-376 Di5.1, whose gauge cluster reads the HAL while reporting
     *  the same `ro.vehicle.type` as SOME/IP trims). The "drive all" controller
     *  fires this alongside SOME/IP; the cluster renders whichever it reads, so a
     *  HAL write on a SOME/IP-only car is a harmless no-op (matches the reference, which
     *  always drives the HAL). The user can still force a single protocol. */
    override fun isAvailable(): Boolean =
        ClusterProtocol.ui == ClusterProtocol.Ui.UI_7_0 ||
            huawei ||
            runCatching {
                com.i99dev.ilink.car.BydAutoFeatureIdsCatalog.isInstrumentDevicePresent()
            }.getOrDefault(false)

    /** Linked once a daemon HAL write has succeeded — the "Live" signal. */
    override fun connected(): Boolean = lastWriteOk

    override fun start() {
        // Bring the persistent shell daemon up (it holds the HAL connection +
        // writes as shell uid — the BYD HAL rejects our app uid).
        runCatching { AdbShellBridge.ensureDaemon() }
    }

    override fun stop() {
        // Short timeout so disarm can never wedge on a half-open daemon socket.
        runCatching { client.send("halGuide", body = { put("on", false) }, timeoutMs = 1_000L) }
        lastWriteOk = false
    }

    override fun push(frame: NavGuidance, counter: Int) {
        // The Huawei HMI cluster's GUIDE_ICON value space is 1153..1182, not our
        // maneuver codes — remap. 7.0UI clusters take our code raw (unchanged).
        val icon = if (huawei) ManeuverCatalog.huaweiClusterIcon(frame.maneuverIcon) else frame.maneuverIcon
        // Stream one frame over the persistent shell daemon (fire-and-forget). The
        // daemon writes the BYD instrument HAL as SHELL uid — the only uid the HAL
        // accepts (proven: `service call autoservice` works as shell, throws as app).
        val ok = client.sendOneWay("halGuide") {
            put("icon", icon)
            put("dist", frame.distanceMeters ?: -1)
            put("road", frame.roadName)
            put("remTime", frame.remainingTimeSeconds ?: -1)
            put("remDist", frame.remainingDistanceMeters ?: -1)
            put("on", true)
            // Camera / safety alerts (P3) — -1 = absent. The cluster shows the glyph.
            put("camType", frame.cameraType ?: -1)
            put("camDist", frame.cameraDistance ?: -1)
            put("camState", frame.cameraState ?: -1)
            put("safeType", frame.safetyType ?: -1)
            put("safeDist", frame.safetyDistance ?: -1)
            put("safeState", frame.safetyState ?: -1)
        }
        lastWriteOk = ok
        if (!ok) {
            Log.w(TAG, "daemon halGuide write failed")
            // On the Huawei trim SOME/IP is gated off, so failing the transport
            // would leave NOTHING — keep retrying each frame until the daemon is up
            // (it spawns asynchronously). 7.0UI keeps the fail-over-to-reselect path.
            if (!huawei) error("daemon halGuide write failed")
        }
    }

    override fun clear() {
        runCatching { client.send("halGuide", body = { put("on", false) }, timeoutMs = 1_000L) }
    }

    private companion object {
        const val TAG = "HalCanFidTransport"
    }
}

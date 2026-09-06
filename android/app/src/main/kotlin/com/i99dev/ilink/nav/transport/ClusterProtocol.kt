package com.i99dev.ilink.nav.transport

/**
 * The ONE source of truth for which BYD DiLink cluster-HUD protocol a car
 * speaks. The factory instrument cluster consumes a DIFFERENT SOME/IP service
 * per DiLink UI generation, so the Nav-HUD transports are hard-partitioned by
 * this — a car only ever uses its own protocol, never the other:
 *
 *  - **5.0UI** (`*_5.0UI` — Di5.0 / Di5.1: Leopard 5/8, Song, Ti7-non-7UI, …):
 *    the cluster reads the **RoadInfo** manual-protobuf event → [SomeIpHudTransport].
 *  - **7.0UI** (`DiLink*_7.0UI` — Leopard 7 / Ti7): the cluster reads the
 *    **HudNaviInfoService** FlatBuffer (service 0x0101) → [HudNaviInfoTransport].
 *
 * Detected once (cached) from `ro.vehicle.type`, which is world-readable (unlike
 * the SELinux-gated `persist.sys.*`). Pure [classify] is host-tested; the
 * Android sysprop read is the only impure seam.
 */
object ClusterProtocol {

    enum class Ui { UI_5_0, UI_7_0, UNKNOWN }

    /** This car's cluster-HUD generation. Cached — `ro.vehicle.type` is fixed. */
    val ui: Ui by lazy { classify(systemProperty("ro.vehicle.type")) }

    /** Pure classifier (host-testable). `7.0UI` wins over `5.0UI` if both ever
     *  appear; unknown/blank → [Ui.UNKNOWN] (treated as 5.0UI-compatible by the
     *  transports, preserving legacy behaviour on trims we haven't profiled). */
    fun classify(vehicleType: String?): Ui = when {
        vehicleType.isNullOrBlank() -> Ui.UNKNOWN
        vehicleType.contains("7.0UI", ignoreCase = true) -> Ui.UI_7_0
        vehicleType.contains("5.0UI", ignoreCase = true) -> Ui.UI_5_0
        else -> Ui.UNKNOWN
    }

    /**
     * Some Di5.1 trims (e.g. code40d 376) ship a **Huawei ADS HMI** instrument
     * cluster (`com.huawei.hibaic.adshmiic`). That cluster ignores the 5.0UI
     * SOME/IP RoadInfo service entirely and renders nav only from the BYD
     * instrument HAL (`BYDAutoInstrumentDevice` / `autoservice`) — the same path
     * 7.0UI uses. Detected by the renderer package's presence (cached). When true,
     * [SomeIpHudTransport] steps aside and the instrument-HAL transport drives the
     * cluster; cars without this package are completely unaffected.
     */
    @Volatile private var huaweiHmi: Boolean = false

    fun isHuaweiHmiCluster(context: android.content.Context): Boolean {
        // Only CACHE a positive result — a transient query failure (e.g. during
        // very-early init) must not pin this to false for the process lifetime.
        if (huaweiHmi) return true
        val present = runCatching {
            context.packageManager.getPackageInfo("com.huawei.hibaic.adshmiic", 0)
            true
        }.getOrDefault(false)
        if (present) huaweiHmi = true
        return present
    }

    private fun systemProperty(key: String): String? = runCatching {
        val cls = Class.forName("android.os.SystemProperties")
        (cls.getMethod("get", String::class.java).invoke(null, key) as? String)
            ?.takeIf { it.isNotEmpty() }
    }.getOrNull()
}

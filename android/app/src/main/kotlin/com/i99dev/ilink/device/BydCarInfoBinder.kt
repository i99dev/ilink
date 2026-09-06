package com.i99dev.ilink.device

import android.content.Context
import android.util.Log

/**
 * Two-tier BYD car-identity probe. Single source of truth for
 * "what car am I running on?" — replaces the previous fan-out of
 * 13 system-property reads with one resolver that surfaces the
 * exact same answer BYD's own apps consume.
 *
 * ## Resolution order
 *
 *   1. **Framework SDK** — reflect into `com.byd.car.ICarInfoManager`.
 *      Wins for system-signed apps (privileged install path) where
 *      the BYD framework is on the classpath. Returns the richer
 *      shape including VIN, brand, body type, driver seat.
 *   2. **System-property fallback** — read
 *      `persist.sys.model_variant.model` (canonical token, e.g.
 *      `fcbsq` for Leopard 8) and `persist.sys.vehicle_40d_code`
 *      (granular trim integer, e.g. `155` for Leopard 8). These
 *      two properties are populated by the same BYD framework
 *      service that backs ICarInfoManager and are readable from
 *      any user-app UID via [SystemProperties]. The fallback
 *      synthesises the identical [Snapshot] shape the framework
 *      path produces, just without the privileged-only fields
 *      (VIN, brand, driverSeat — left null/-1).
 *
 * ## Why two paths
 *
 * Live testing on a Leopard 8 (2026-05-10) confirmed the framework
 * `Class.forName("com.byd.car.ICarInfoManager")` throws
 * `ClassNotFoundException` for non-platform-signed apps — the
 * BYD framework jar isn't visible to user-app classloaders. The
 * sysprop fallback captures the same trim-precise signal because
 * the same framework writes both the binder AND the props at
 * boot — they don't diverge.
 *
 * ## Coverage
 *
 * 21 canonical model strings via the framework path; the same 21
 * via the sysprop path, identified by uppercasing
 * `persist.sys.model_variant.model`. Trim-precise routing inside
 * FangChengBao (L5/L5L/L5U/L7/L8) uses the integer
 * `vehicle_40d_code` as the disambiguator.
 *
 * ## Lifecycle
 *
 * One-shot per session. The Dart-side detector calls
 * `ilink/model_detector` → `getCarInfo` once at boot and caches
 * the result for the rest of the process.
 *
 * ## Failure mode
 *
 * Both paths returning empty (non-BYD HU, neither framework nor
 * BYD sysprops present) yields `null`. The Dart side treats null
 * as "not on a BYD head unit" and falls through to
 * [ModelId.unknown]. No app-boot-blocking exceptions.
 */
class BydCarInfoBinder(private val applicationContext: Context) {

    /**
     * Frozen identity snapshot. Field shapes mirror the BYD SDK
     * methods 1:1 — see KDoc on each field for the source method
     * and the value-space contract.
     *
     * Null/-1 indicate a single field wasn't reachable; the whole
     * snapshot is null when the SDK class itself isn't bound.
     */
    data class Snapshot(
        /** `ICarInfoManager.getCarType()` — one of 21 canonical
         *  strings (HAN, TANG, SONG, QIN, XIA, SEAL, SEALION,
         *  DOLPHIN, N7-N9, D9, Z9, FCBSF, FCBSQ, FCBURE, R1-R4,
         *  unknown). Drives variantId resolution. */
        val carType: String?,
        /** `ICarInfoManager.getBrand()` — DYNASTY / OCEAN / DENZA
         *  / F (FangChengBao) / R (Yangwang) / UNKNOWN. */
        val brand: String?,
        /** `ICarInfoManager.getVehicleType()` — body class
         *  (CAR / SUV / MPV / TRUCK / …). Distinct from
         *  [carType]; both come from the same manager. */
        val bodyType: String?,
        /** `ICarInfoManager.getVehicleId()` — granular int code
         *  ("model_value" property under the hood). Distinguishes
         *  trims that share a [carType] (e.g. all Leopard 5
         *  variants share `FCBSF` but differ here). -1 when unset. */
        val vehicleId: Int,
        /** `ICarInfoManager.getSerialNumber()` — VIN. */
        val vin: String?,
        /** `ICarInfoManager.getPowerType()` — int encoding of
         *  EV / PHEV / ICE class. -1 when unset. */
        val powerType: Int,
        /** `ICarInfoManager.getDriverSeat()` — left/right indicator.
         *  -1 when unset. */
        val driverSeat: Int,
        /** `persist.sys.byd.default_name` — the BYD nameplate token
         *  (e.g. `海狮06DM-i`, `钛7`, `豹5`). Read from the sysprop on
         *  BOTH paths (it's an unprivileged persist prop). The last-
         *  resort disambiguator for trims the (carType, vehicleId) pair
         *  can't pin: e.g. the Sealion 6 DM-i reports
         *  `model_variant.model=unknown` + `vehicle_40d_code=0`, so the
         *  Dart resolver keys on this nameplate. Null when empty. */
        val defaultName: String?,
    ) {
        /** Wire shape consumed by the Dart channel — keys must match
         *  the field names parsed in `model_detector.dart:_classify`. */
        fun toMap(): Map<String, Any?> = mapOf(
            "carType" to carType,
            "brand" to brand,
            "bodyType" to bodyType,
            "vehicleId" to vehicleId,
            "vin" to vin,
            "powerType" to powerType,
            "driverSeat" to driverSeat,
            "defaultName" to defaultName,
        )
    }

    /**
     * Bind, query, return. Returns null when the SDK isn't on this
     * runtime — non-BYD device, stripped framework, security gate,
     * or any reflection failure. Per-method failures collapse to
     * null/-1 inside an otherwise-valid snapshot so a single missing
     * accessor doesn't drop the whole identity.
     */
    fun snapshot(): Snapshot? {
        // Tier 1 — framework path. Wins on system-signed installs.
        val viaFramework = snapshotViaFramework()
        if (viaFramework != null) {
            Log.i(TAG, "snapshot via framework: ${describe(viaFramework)}")
            return viaFramework
        }
        // Tier 2 — sysprop fallback. Same trim-precise signal,
        // available to any user-app UID. Universally reliable on
        // BYD head units regardless of app-signing.
        val viaSysprops = snapshotViaSysprops()
        if (viaSysprops != null) {
            Log.i(TAG, "snapshot via sysprops: ${describe(viaSysprops)}")
            return viaSysprops
        }
        // Neither path produced a result — not a BYD head unit (or
        // a stripped ROM where both paths are unavailable).
        Log.w(TAG, "snapshot: neither framework nor sysprops produced identity")
        return null
    }

    // ── Tier 1: framework SDK reflection ─────────────────────────

    private fun snapshotViaFramework(): Snapshot? {
        return try {
            val mgrClass = Class.forName(MGR_CLASS)
            val spiClass = Class.forName(SPI_CLASS)
            val getService = spiClass.getMethod(
                "getService",
                Context::class.java,
                Class::class.java,
            )
            val mgr = getService.invoke(null, applicationContext, mgrClass)
                ?: return null
            Snapshot(
                carType = invokeStringOrNull(mgr, mgrClass, "getCarType"),
                brand = invokeStringOrNull(mgr, mgrClass, "getBrand"),
                bodyType = invokeStringOrNull(mgr, mgrClass, "getVehicleType"),
                vehicleId = invokeIntOrDefault(mgr, mgrClass, "getVehicleId", -1),
                vin = invokeStringOrNull(mgr, mgrClass, "getSerialNumber"),
                powerType = invokeIntOrDefault(mgr, mgrClass, "getPowerType", -1),
                driverSeat = invokeIntOrDefault(mgr, mgrClass, "getDriverSeat", -1),
                // Nameplate is an unprivileged persist prop — read it even on
                // the framework path so the Dart resolver can disambiguate a
                // sub-trim the SDK carType alone can't (e.g. SEALION covers the
                // whole Sealion line; 海狮06DM-i pins the 6 DM-i).
                defaultName = readSysprop("persist.sys.byd.default_name"),
            )
        } catch (t: Throwable) {
            // Expected on user-app installs — class isn't on the
            // user classloader. Logged at INFO (not WARN) so the
            // common case stays quiet.
            Log.i(TAG, "framework path unavailable: ${t.javaClass.simpleName}")
            null
        }
    }

    // ── Tier 2: system-property fallback ─────────────────────────

    /**
     * Synthesise a [Snapshot] from BYD's writable system properties.
     * The same framework service that backs `ICarInfoManager` writes
     * these props at boot, so the (carType, vehicleId) pair is
     * identical to what the framework call would return.
     *
     * Properties consumed:
     *   * `persist.sys.model_variant.model` → uppercased to canonical
     *     `carType` (e.g. `fcbsq` → `FCBSQ`, `tang` → `TANG`).
     *   * `persist.sys.vehicle_40d_code` → integer `vehicleId`.
     *     Distinguishes FCB sub-trims (L5=153, L8=155, …).
     *   * `persist.sys.byd.default_name` → captured for triage
     *     diagnostics (Sentry context); not used by the Dart-side
     *     resolver after the rewrite.
     *
     * Returns null when **neither** property reports a useful value
     * — that's "no BYD framework wrote these", treated as "not a
     * BYD head unit". A non-null return means at least one signal
     * was usable; missing fields stay null/-1 so downstream
     * resolution can still gracefully degrade.
     */
    private fun snapshotViaSysprops(): Snapshot? {
        val variantToken = readSysprop("persist.sys.model_variant.model")
        val code40dStr = readSysprop("persist.sys.vehicle_40d_code")
        val defaultName = readSysprop("persist.sys.byd.default_name")
        val carType = variantToken
            ?.takeIf { it.isNotBlank() && !it.equals("unknown", ignoreCase = true) }
            ?.uppercase()
        val vehicleId = code40dStr?.toIntOrNull() ?: -1
        // A bare nameplate is enough to keep the snapshot alive: trims like
        // the Sealion 6 DM-i report model_variant=unknown + code40d=0 (so
        // carType=null, vehicleId<=0) yet are still resolvable from
        // default_name. Bail only when NONE of the three signals is useful.
        if (carType == null && vehicleId < 0 && defaultName.isNullOrBlank()) {
            return null
        }
        return Snapshot(
            carType = carType,
            // brand / vin / bodyType / powerType / driverSeat are
            // privileged-only fields — left null/-1 on the sysprop
            // path. The Dart resolver doesn't need them for variantId
            // resolution; Sentry context simply omits them.
            brand = null,
            bodyType = null,
            vehicleId = vehicleId,
            vin = null,
            powerType = -1,
            driverSeat = -1,
            defaultName = defaultName,
        )
    }

    // ── Sysprop reader (shared with the framework-path safety net) ─

    private val getSyspropMethod: java.lang.reflect.Method? by lazy {
        try {
            Class.forName("android.os.SystemProperties")
                .getMethod("get", String::class.java, String::class.java)
        } catch (t: Throwable) {
            null
        }
    }

    private fun readSysprop(key: String): String? {
        return try {
            val m = getSyspropMethod ?: return null
            (m.invoke(null, key, "") as? String)?.takeIf { it.isNotEmpty() }
        } catch (t: Throwable) {
            null
        }
    }

    // ── Diagnostics ──────────────────────────────────────────────

    private fun describe(s: Snapshot): String = buildString {
        append("carType=").append(s.carType)
        append(" brand=").append(s.brand)
        append(" vehicleId=").append(s.vehicleId)
        append(" bodyType=").append(s.bodyType)
        append(" powerType=").append(s.powerType)
        // VIN intentionally elided — keep the log line PII-clean.
        // Sentry still gets the full snapshot via setTrimContext.
    }

    private fun invokeStringOrNull(
        target: Any,
        cls: Class<*>,
        name: String,
    ): String? = try {
        (cls.getMethod(name).invoke(target) as? String)?.takeIf { it.isNotBlank() }
    } catch (t: Throwable) {
        null
    }

    private fun invokeIntOrDefault(
        target: Any,
        cls: Class<*>,
        name: String,
        default: Int,
    ): Int = try {
        cls.getMethod(name).invoke(target) as? Int ?: default
    } catch (t: Throwable) {
        default
    }

    companion object {
        private const val TAG = "BydCarInfo"
        private const val MGR_CLASS = "com.byd.car.ICarInfoManager"
        private const val SPI_CLASS = "com.byd.spi.Spi"
    }
}

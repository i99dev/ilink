package com.i99dev.ilink.car

import android.content.Context
import android.os.Build
import android.util.Log
import com.i99dev.ilink.adb.AdbShellBridge
import java.io.FileInputStream
import java.util.Properties

/**
 * Reflection-based identity probe of the BYD head unit. Everything
 * returned is safe to ship over the compat report — no raw VIN, no
 * user data, just build / firmware / service-availability hints that
 * help correlate which BYD model a report came from on the backend.
 *
 * Every probe is isolated in a try/catch: on an unexpected DiLink
 * build where a class is missing or a service name changed, the
 * corresponding key drops rather than crashing the whole map.
 */
object CarIdentity {
    private const val TAG = "CarIdentity"

    fun snapshot(context: Context): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>(
            "android_build_manu" to (Build.MANUFACTURER ?: ""),
            "android_build_model" to (Build.MODEL ?: ""),
            "android_sdk_int" to Build.VERSION.SDK_INT,
        )
        out["byd_auto_mgr_present"] = probeClass("android.hardware.bydauto.BYDAutoManager")
        out["byd_airconditioning_present"] = probeService("byd_airconditioning")
        out["dilink_version_hint"] = probeDilinkVersion()
        return out
    }

    /**
     * Privacy-sensitive identity surface — device_id, vehicle
     * code, region. Returned values MUST stay on-device unless hashed
     * via `lib/features/compat/data/device_id_hasher.dart` first.
     * Used by the developer test bench AND by
     * [deviceFingerprintProvider] for the pair handshake.
     *
     * Never call from the compat-report path — that's [snapshot]
     * above which deliberately omits anything user-identifying.
     *
     * **Important: `vin` here is BYD's cloud-side device identifier,
     * NOT the ISO 17-character VIN.** What the L8 exposes via
     * `persist.sys.cloud.last_vin` is `byd<hex16>` (e.g.
     * `bydE51DB8F5AE5E3713`) — derived at factory from this head
     * unit's hardware fingerprint, unique per vehicle, used by BYD
     * cloud (`mqttserv`, `cloud_server_app_service`) as the binding
     * key. The legal ISO VIN stamped on the chassis lives on CAN bus
     * + the `mycar` service binder which requires platform-signed
     * access — out of reach for a third-party app.
     *
     * For our backend pair flow this IS the right unique id: stable,
     * factory-set, never collides across cars. Documenting the
     * distinction so future code doesn't try to validate this string
     * against ISO 3779 (the 17-char regex in DeviceFingerprint
     * intentionally tolerates non-ISO ids).
     *
     * Read path: reflection on `android.os.SystemProperties.get(String)`
     * (class is `@hide` but every Android image ships it).
     */
    fun localOnly(): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>()
        // Prefixed canonical device id per RENAME_BYD_DEVICE_ID_CONTRACT.md:
        // BYD-side native id (NOT chassis VIN — see class doc above for
        // the distinction) wrapped in `byd:<native_id>`. Try
        // BYD-specific keys first; AOSP fallback last. Order matches
        // what the L8 capture in .secrets/research/l8/01-vehicle-info.md
        // found populated.
        val deviceIdKeys = listOf(
            "persist.sys.cloud.last_vin",
            "persist.sys.dms.config.vin",
            "sys.virtual.vin",
            "sys.dms.config.vin",
        )
        for (k in deviceIdKeys) {
            // Direct reflection first. On Android 13+ with SELinux Enforcing
            // (Di5.1 ROMs) the app domain is DENIED reading these vin props, so
            // the reflection returns empty — fall back to the shell bridge
            // (uid 2000, which CAN read them). The shell read is a no-op until
            // the daemon is up, so login (pre-bootstrap) isn't blocked; the
            // correct id resolves once the bridge is live and the install
            // re-homes to it.
            val v = systemProperty(k) ?: shellProperty(k)
            if (!v.isNullOrBlank()) {
                out["device_id"] = "byd:$v"
                out["device_id_source"] = k
                break
            }
        }
        // Car-mode-id — BYD-internal vehicle code. Live-verified on a
        // 2024 Leopard 8 (UAE): canonical key is
        // `persist.sys.vehicle_40d_code` ("155" = Leopard 8). The
        // legacy `persist.sys.car.mode.id` and `ro.byd.car.modeid`
        // exist in AOSP samples but stay empty on shipping BYD
        // firmware — kept as fallbacks for older/non-DiLink-5 trims.
        val carModeId = systemProperty("persist.sys.vehicle_40d_code")
            ?: systemProperty("persist.sys.car.mode.id")
            ?: systemProperty("ro.byd.car.modeid")
        if (!carModeId.isNullOrBlank()) out["car_mode_id"] = carModeId

        // Model variant code — finer-grained than mode_id ("fcbsq" on
        // the L8 we audited). Distinguishes ME/CN trims of the same
        // mode id so the backend can gate per-market features.
        val modelVariant = systemProperty("persist.sys.model_variant.model")
        if (!modelVariant.isNullOrBlank()) out["model_variant"] = modelVariant

        // Vehicle type string — "Di5.1_5.0UI" on the L8. Useful for
        // gating ADAS layer expectations against firmware version.
        val vehicleType = systemProperty("ro.vehicle.type")
        if (!vehicleType.isNullOrBlank()) out["vehicle_type"] = vehicleType

        // Head-unit firmware identifier — "DiLink5.1" on the L8.
        val headUnit = systemProperty("ro.product.model")
        if (!headUnit.isNullOrBlank()) out["head_unit"] = headUnit

        // Region — derived from the SIM's ISO country, most reliable
        // on the L8 since the BYD-specific region keys aren't always
        // populated. Falls through to legacy keys for compat.
        val region = systemProperty("gsm.sim.operator.iso-country")
            ?: systemProperty("gsm.operator.iso-country")
            ?: systemProperty("persist.sys.byd.region")
            ?: systemProperty("ro.byd.region")
        if (!region.isNullOrBlank()) out["region"] = region

        // BYD-authoritative trim signals. The outswver string is the
        // only signal that reliably separates Leopard 5 base / Ultra
        // / Lidar; the default_name carries the Chinese model token
        // (豹5 / 豹8 / 钛7) needed to disambiguate outsw keys that are
        // shared across trims.
        val outsw = systemProperty("apps.setting.product.outswver")
        if (!outsw.isNullOrBlank()) out["outsw"] = outsw
        val defaultName = systemProperty("persist.sys.byd.default_name")
        if (!defaultName.isNullOrBlank()) out["default_name"] = defaultName

        // Friendly model name. Exposed separately from car_mode_id /
        // outsw so UI can show "Leopard 8" while the backend keeps
        // using the stable code identifiers.
        val mode = (out["car_mode_id"] as? String) ?: ""
        val friendly = bydModelName(mode, outsw, defaultName)
        if (friendly != null) out["model_name"] = friendly

        return out
    }

    /**
     * BYD model code → human-readable name. Resolution priority:
     *
     *   1. `apps.setting.product.outswver` `<major>.<minor>.<modelCode>`
     *      prefix (and `persist.sys.byd.default_name` as a Chinese-
     *      token disambiguator for outsw keys shared across trims).
     *      Empirically validated across the Leopard / HAN L line.
     *   2. Legacy `persist.sys.vehicle_40d_code` mapping —
     *      `155` → Leopard 8, kept as a fallback for Leopard 8
     *      ROMs predating the outswver convention.
     *
     * Unknown values return null; callers fall back to model_variant
     * or the Android Build.MODEL string.
     */
    /**
     * Resolve the [SubTrim] for the active vehicle.
     *
     * Primary signal is `persist.sys.vehicle_40d_code` — BYD's
     * canonical trim integer, written by the same framework that
     * backs `ICarInfoManager`. Per [BydCarInfoBinder], code40d=155
     * pins Leopard 8 BASE, code40d=153 pins Leopard 5 NAVIGATOR,
     * etc. This matches the variant resolution path used by
     * `model_detector.dart:_resolveModel`, so subTrim and variant
     * stay coherent.
     *
     * Sub-trims that share a code40d (or where the integer hasn't
     * been observed yet) fall back to the legacy outswver +
     * default_name parsing — kept as a defensive secondary path
     * until every L5L / L5U / L7 / Han L unit's code40d has
     * surfaced to telemetry. Once observed, the row moves to the
     * primary `when` block and the fallback row can be removed.
     *
     * Returns null when neither signal pins a known sub-trim — the
     * resolver then walks tier-3 (trim aggregate) instead.
     */
    fun resolveSubTrim(): SubTrim? {
        // Primary — vehicle_40d_code. Live-validated:
        //   * L8: code40d=155 → BASE (single-trim FCB family).
        //   * L5: code40d=153 → NAVIGATOR (per Leopard5.kt).
        // Add rows as L5L / L5U / L7 / HAN L code40d's surface
        // through fleet telemetry.
        val code40d = systemProperty("persist.sys.vehicle_40d_code")
        when (code40d) {
            "155" -> return SubTrim.BASE
            "153" -> return SubTrim.NAVIGATOR
            "243" -> return SubTrim.BASE  // Song PLUS — single-trim
            "282" -> return SubTrim.BASE  // Leopard 7 (Ti7/钛7) — single-trim; live 2026-06-11
            "304" -> return SubTrim.ULTRA  // Leopard 5 Ultra (Di5.1/XDJA) — live 2026-06-11
            "330" -> return SubTrim.BASE  // Song PLUS Smart Drive (BEV, Di5.0) — single-trim; live 2026-06-12
        }

        // Fallback — legacy outswver disambiguation. Triggered for
        // trims whose code40d we haven't profiled yet. The rows
        // here mirror the pre-2026-05-10 detector logic 1:1 so
        // existing subTrim resolution doesn't regress on an
        // un-upgraded ROM.
        val outsw = systemProperty("apps.setting.product.outswver")
        val defaultName = systemProperty("persist.sys.byd.default_name") ?: ""
        val key = outsw
            ?.split('.')
            ?.takeIf { it.size >= 3 }
            ?.let { "${it[0]}.${it[1]}.${it[2]}" }
        return when (key) {
            "23.1.4" -> SubTrim.NAVIGATOR
            "23.1.24" -> when {
                defaultName.contains("豹5") -> SubTrim.NAVIGATOR
                else -> null
            }
            "34.1.17" -> when {
                defaultName.contains("豹5") -> SubTrim.LIDAR
                defaultName.contains("豹8") -> SubTrim.BASE
                else -> null
            }
            "34.1.23" -> SubTrim.ULTRA
            "34.1.11", "34.1.15" -> SubTrim.BASE
            // 34.1.35 = Leopard 7. Outsw fallback so an L7 reporting an
            // unset code40d (=0) still resolves a sub-trim here — live
            // 2026-06-12. (bydModelName already maps 34.1.35 → name.)
            "34.1.35" -> SubTrim.BASE
            else -> null
        }
    }

    /**
     * Resolve the active vehicle's DiLink generation. ``ro.vehicle.type``
     * is the most reliable signal — the prefix (`Di5.0_*` / `Di5.1_*`)
     * is consistent across firmware versions.
     */
    fun resolveDilinkFamily(): String {
        val vt = systemProperty("ro.vehicle.type") ?: ""
        return when {
            // Internal form (`Di5.1_*`/`Di5.0_*`) and the public
            // marketing-number form (`DiLink150_*` = 5.1,
            // `DiLink100_*` = 5.0). The latter is live on the
            // Leopard 7 (`ro.vehicle.type="DiLink150_7.0UI"`,
            // 2026-06-11) — without it L7 resolved to "unknown".
            vt.startsWith("Di5.1") || vt.startsWith("DiLink150") -> "di5.1"
            vt.startsWith("Di5.0") || vt.startsWith("DiLink100") -> "di5.0"
            else -> "unknown"
        }
    }

    /**
     * The friendly model name only ("Leopard 8", "Leopard 5 Ultra", …), or null
     * when nothing pins it.
     *
     * Same resolution as [localOnly]'s `model_name` — it calls the very same
     * [bydModelName] — but reads ONLY system properties: no `AdbShellBridge`
     * round-trip, no device id, nothing privacy-sensitive. That makes it safe to
     * call from a main-thread path (option resolution at plugin build) where
     * [localOnly] is not: [localOnly] may block on up to four 2 s shell reads
     * while probing the vin keys.
     */
    fun modelName(): String? {
        val carModeId = systemProperty("persist.sys.vehicle_40d_code")
            ?: systemProperty("persist.sys.car.mode.id")
            ?: systemProperty("ro.byd.car.modeid")
            ?: ""
        return bydModelName(
            carModeId,
            systemProperty("apps.setting.product.outswver"),
            systemProperty("persist.sys.byd.default_name"),
        )
    }

    private fun bydModelName(
        carModeId: String,
        outsw: String?,
        defaultName: String?,
    ): String? {
        val key = outsw
            ?.split('.')
            ?.takeIf { it.size >= 3 }
            ?.let { "${it[0]}.${it[1]}.${it[2]}" }
        val name = defaultName ?: ""
        val byOutsw: String? = when (key) {
            "23.1.4" -> "Leopard 5"
            "23.1.24" -> when {
                name.contains("豹5") -> "Leopard 5"
                name.contains("钛7") -> "Leopard 7"
                else -> null
            }
            "34.1.11" -> "BYD HAN L"
            // 34.1.15 and 34.1.35 both seen on Leopard 7 ROMs; the
            // newer 34.1.35 is live-confirmed (default_name 钛7,
            // code40d 282, 2026-06-11).
            "34.1.15", "34.1.35" -> "Leopard 7"
            "34.1.17" -> when {
                name.contains("豹5") -> "Leopard 5 Lidar"
                name.contains("豹8") -> "Leopard 8"
                else -> null
            }
            "34.1.23" -> "Leopard 5 Ultra"
            else -> null
        }
        if (byOutsw != null) return byOutsw
        return when (carModeId) {
            "155" -> "Leopard 8"
            "282" -> "Leopard 7"  // code40d backstop — live 2026-06-11
            "304" -> "Leopard 5 Ultra"  // code40d backstop — live 2026-06-11
            "330" -> "Song PLUS Smart Drive"  // code40d backstop — live 2026-06-12
            else -> null
        }
    }

    private fun systemProperty(key: String): String? {
        return try {
            val cls = Class.forName("android.os.SystemProperties")
            val m = cls.getMethod("get", String::class.java)
            (m.invoke(null, key) as? String)?.takeIf { it.isNotEmpty() }
        } catch (e: Throwable) {
            Log.d(TAG, "systemProperty('$key') failed: ${e.message}")
            null
        }
    }

    /**
     * Read a system property via the loopback shell bridge (uid 2000, shell
     * SELinux domain) — for properties the APP domain (untrusted_app) is denied
     * reading directly on Android 13+ SELinux-Enforcing ROMs (e.g. the BYD
     * device-id vin). No-op until the daemon/bridge is live, so it never blocks
     * the pre-bootstrap login path. Bounded + best-effort.
     */
    private fun shellProperty(key: String): String? {
        if (!AdbShellBridge.isConnected()) return null
        return runCatching {
            AdbShellBridge.shell("getprop $key", 2_000L).trim().takeIf { it.isNotEmpty() }
        }.onFailure { Log.d(TAG, "shellProperty('$key') failed: ${it.message}") }.getOrNull()
    }

    private fun probeClass(fqcn: String): Boolean =
        try {
            Class.forName(fqcn)
            true
        } catch (e: Throwable) {
            Log.d(TAG, "class probe '$fqcn' failed: ${e.message}")
            false
        }

    /**
     * Returns true if `ServiceManager.getService(name)` resolves to a
     * non-null binder. Uses reflection because `ServiceManager` is
     * `@hide` — calling it directly requires the app to be signed with
     * the platform key.
     */
    private fun probeService(name: String): Boolean =
        try {
            val sm = Class.forName("android.os.ServiceManager")
            val get = sm.getMethod("getService", String::class.java)
            val binder = get.invoke(null, name)
            binder != null
        } catch (e: Throwable) {
            Log.d(TAG, "service probe '$name' failed: ${e.message}")
            false
        }

    /**
     * Best-effort DiLink version hint from `/system/build.prop`. BYD
     * writes several `ro.byd.*` / `ro.dilink.*` keys; we try a handful
     * and return the first one that resolves. Returns null if none
     * are readable (strict SELinux, newer firmware that dropped them,
     * etc.).
     */
    private fun probeDilinkVersion(): String? {
        val candidates = listOf(
            "ro.dilink.version",
            "ro.byd.dilink.version",
            "ro.byd.sw.version",
            "ro.byd.hu.version",
        )
        return try {
            val props = Properties().apply {
                FileInputStream("/system/build.prop").use { load(it) }
            }
            for (k in candidates) {
                val v = props.getProperty(k)
                if (!v.isNullOrBlank()) return v
            }
            null
        } catch (e: Throwable) {
            Log.d(TAG, "dilink version probe failed: ${e.message}")
            null
        }
    }
}

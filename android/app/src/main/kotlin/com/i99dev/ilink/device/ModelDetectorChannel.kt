package com.i99dev.ilink.device

import android.content.Context
import com.i99dev.ilink.miniapps.MiniAppDispatcher
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Platform channel for the Dart-side `ModelDetector` and
 * `HuVendorDetector`. Two distinct concerns sharing one channel
 * because both are read-only identity probes that fire once at
 * boot, and the channel is already the hot-path entry point both
 * detectors expect.
 *
 *   * `getCarInfo` — primary car identity. Wraps
 *     [BydCarInfoBinder] which reflects into BYD's
 *     `ICarInfoManager` SDK. Returns the canonical 21-string
 *     `carType` plus brand / VIN / vehicleId / powerType / body
 *     type. **Replaced the previous 13-property sysprop fan-out
 *     in 2026-05-10** — outsw + default_name parsing was retired
 *     in favour of BYD's own service. See
 *     `model_detector.dart` for the consumer.
 *   * `readVendorProps` — head-unit chassis fingerprint
 *     (`ro.product.brand` / `manufacturer` / `build.fingerprint`).
 *     Consumed by [com.i99dev.ilink.car.support.HuVendorDetector] only;
 *     orthogonal to the car identity above.
 *   * `getProfileOverride` / `setProfileOverride` — user-facing
 *     manual override of the resolved variant. Persisted in
 *     SharedPreferences across reboots.
 *   * `setModelId` — Dart pushes the resolved id chain back so
 *     [MiniAppDispatcher]'s `model_match` selector has values to
 *     match against.
 *
 * Read once at boot; the Dart-side detectors cache the result for
 * the rest of the process.
 */
class ModelDetectorChannel(
    private val applicationContext: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "ilink/model_detector")

    /** Lazily-built binder — reflection load is cheap, but defer
     *  it until the first `getCarInfo` call so we don't pay it on
     *  channel construction. */
    private val carInfoBinder by lazy { BydCarInfoBinder(applicationContext) }

    /** SharedPreferences for the user's vehicle-profile override.
     *  See [getProfileOverride] / [setProfileOverride] for the
     *  contract; see `model_detector.dart` for how the override is
     *  applied at classify time. Lazily read once per get/set so
     *  rotation doesn't require a re-init. */
    private val prefs by lazy {
        applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getCarInfo" -> result.success(getCarInfo())
                "readVendorProps" -> result.success(readVendorProps())
                "getProfileOverride" -> result.success(getProfileOverride())
                "setProfileOverride" -> {
                    val variant = call.argument<String?>("variant")
                    setProfileOverride(variant)
                    result.success(null)
                }
                "setModelId" -> {
                    // Dart-side `ModelDetector.detect()` pushes the
                    // resolved id chain back here so the dispatcher's
                    // model_match selector has values to match
                    // against. Idempotent on the Kotlin side.
                    //
                    // Two arg shapes accepted:
                    //   * `ids: [variant?, dilinkFamily]` — preferred,
                    //     finest-to-coarsest. Lets routes targeting
                    //     either level still match.
                    //   * `id: "<single>"` — legacy single-string
                    //     fallback for older Dart code paths.
                    val ids = call.argument<List<String>>("ids")
                    if (ids != null) {
                        MiniAppDispatcher.setModelIds(ids)
                    } else {
                        val id = call.argument<String>("id") ?: "unknown"
                        MiniAppDispatcher.setModelId(id)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    /**
     * Primary car-identity probe. Returns the BYD SDK snapshot as
     * a Map (wire shape per [BydCarInfoBinder.Snapshot.toMap]) plus
     * one legacy sysprop, `ro.vehicle.type`, kept solely to derive
     * DiLink generation — the SDK doesn't expose that directly and
     * generation is the only other axis the Dart-side resolver
     * needs. Returns null when the BYD SDK isn't bindable on this
     * runtime; the Dart side treats null as "not a BYD car" and
     * surfaces [ModelId.unknown].
     */
    private fun getCarInfo(): Map<String, Any?>? {
        val snap = carInfoBinder.snapshot() ?: return null
        return snap.toMap() + mapOf(
            // Single legacy property kept: the ICarInfoManager API
            // doesn't expose DiLink generation directly, but the
            // Dart resolver needs it for the family-level fallback
            // chain (when carType is null/unknown but Di5.x is
            // still a useful selector). Reading one sysprop here is
            // cheaper than introducing a second binder.
            "dilinkRaw" to readSysprop("ro.vehicle.type"),
            // Three signals that aren't BYD-binder-derivable but the
            // sign-in fingerprint + Sentry tags need them. Folded
            // into ModelInfo so we have ONE source of truth instead
            // of a parallel sysprop fan-out (the legacy
            // `CarIdentity.localOnly()` path is being retired —
            // see Phase A of the detection-consolidation plan).
            //
            //   make     — coarse vendor (BYD / GeneralMotors / …),
            //              useful when adding non-BYD support later.
            //   headUnit — firmware family marker ("DiLink5.1"),
            //              distinct concern from vehicle id but
            //              tagged on installs for support triage.
            //   region   — SIM-derived ISO country, used by backend
            //              for locale routing on first contact (the
            //              Telegram bot's first reply lands in the
            //              right language).
            "make" to android.os.Build.MANUFACTURER?.takeIf { it.isNotBlank() },
            "headUnit" to readSysprop("ro.product.model"),
            "region" to readSysprop("gsm.sim.operator.iso-country"),
        )
    }

    /**
     * HU vendor probe — head-unit chassis brand fingerprint plus
     * BYD-namespace positive markers. Consumed by
     * `HuVendorDetector` to bucket the chassis (BYD stock,
     * aftermarket forks like Dudu / Yuanfeng / Desay). Distinct
     * from car identity: this answers "whose head-unit is this?",
     * not "which BYD model is this?". Both share the channel
     * because both are read-only one-shot probes that run at boot.
     *
     * The BYD-namespace props (`apps.setting.product.outswver`,
     * `persist.sys.byd.default_name`, `ro.byd.ui.*`) function as
     * a positive BYD signal — aftermarket forks don't carry them.
     * They duplicate keyspace with the (now-retired) car-model
     * sysprop fan-out, but the consumers are different so
     * presenting them through this method keeps the surfaces
     * decoupled.
     */
    private fun readVendorProps(): Map<String, String?> = mapOf(
        "ro.product.brand" to readSysprop("ro.product.brand"),
        "ro.product.manufacturer" to readSysprop("ro.product.manufacturer"),
        "ro.build.fingerprint" to readSysprop("ro.build.fingerprint"),
        // BYD positive markers — first hit any of these proves
        // first-party BYD chassis without pinning the car model.
        "apps.setting.product.outswver" to readSysprop("apps.setting.product.outswver"),
        "persist.sys.byd.default_name" to readSysprop("persist.sys.byd.default_name"),
        "ro.byd.ui.splitscreen" to readSysprop("ro.byd.ui.splitscreen"),
        "ro.byd.ui.platformized" to readSysprop("ro.byd.ui.platformized"),
    )

    /// Reflection-resolved [SystemProperties.get] handle, cached on
    /// first use. Null when the class is missing entirely (very old
    /// or stripped-down Android variants).
    private val getMethod: java.lang.reflect.Method? by lazy {
        try {
            Class.forName("android.os.SystemProperties")
                .getMethod("get", String::class.java, String::class.java)
        } catch (t: Throwable) {
            null
        }
    }

    private fun readSysprop(key: String): String? {
        return try {
            val m = getMethod ?: return null
            (m.invoke(null, key, "") as? String)?.takeIf { it.isNotEmpty() }
        } catch (t: Throwable) {
            null
        }
    }

    /**
     * Read the user's vehicle-profile override variant id, or null
     * when no override is set. Persisted across reboots in
     * SharedPreferences. The override only replaces the resolved
     * variantId — the rest of the snapshot (carType, vehicleId,
     * brand, …) still reflects the actual ROM.
     */
    private fun getProfileOverride(): String? {
        return prefs.getString(KEY_OVERRIDE, null)?.takeIf { it.isNotBlank() }
    }

    /**
     * Set or clear the user's vehicle-profile override variant id.
     * Pass null (or an empty string) to clear; pass any of the
     * resolver's known variant ids to force-pick. Idempotent.
     */
    private fun setProfileOverride(variant: String?) {
        val editor = prefs.edit()
        if (variant.isNullOrBlank()) {
            editor.remove(KEY_OVERRIDE)
        } else {
            editor.putString(KEY_OVERRIDE, variant)
        }
        editor.apply()
    }

    companion object {
        private const val PREFS_NAME = "ilink.car_identity"
        private const val KEY_OVERRIDE = "vehicle_profile_override"
    }
}

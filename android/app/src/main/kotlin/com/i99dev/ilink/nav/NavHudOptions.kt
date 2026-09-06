package com.i99dev.ilink.nav

import android.content.Context
import com.i99dev.ilink.nav.transport.someip.SomeIpVariants

/**
 * Live, user-tunable Nav-HUD options (set from the Flutter settings panel via
 * the `setOption` channel method). Read by the ingestion/transport paths. Single
 * source of truth — no per-call plumbing.
 *
 * Values are persisted to SharedPreferences so a choice survives process death /
 * car restart. [init] loads them once at plugin construction; [set] is the only
 * mutator and writes through. Fields are read-only outside this object (the
 * `setOption` channel is the one entry point).
 */
object NavHudOptions {
    /** Fold non-Latin road names to ASCII for Latin-only clusters (default ON). */
    @Volatile var transliterate: Boolean = true
        private set

    /** Push Waze speed-camera / police alerts to the cluster safety glyph. */
    @Volatile var cameraAlerts: Boolean = true
        private set

    /** Also drive BYD's native Amap dashboard widget via broadcast (dual output). */
    @Volatile var amapWidget: Boolean = true
        private set

    /** Auto-arm the cluster HUD when voice navigation starts. */
    @Volatile var autoStart: Boolean = true
        private set

    /** Persistent on/off for the whole cluster HUD. Once the user turns it on it
     *  STAYS on across app restarts / car reboots — the plugin auto-arms on init
     *  when this is true, so the user never has to re-activate it each launch.
     *  Flipped by the arm/disarm channel calls, not a user "option" toggle. */
    @Volatile var hudEnabled: Boolean = false
        private set

    /** Which cluster-HUD transport(s) to drive. Trims with identical
     *  `ro.vehicle.type` can read different protocols, so the default `auto` drives
     *  EVERY available transport at once (SOME/IP + CAN-FID + Amap) and lets the
     *  cluster render whichever it reads. `someip` / `canfid` force a single channel
     *  for diagnosis. One of: `auto`, `someip`, `canfid`. */
    @Volatile var clusterProtocol: String = "auto"
        private set

    /** Which SOME/IP wire *variant* to speak. `auto` (stored default) derives it
     *  from the detected model; an explicit id (`ui7`) OVERRIDES that derivation
     *  and pins the wire.
     *
     *  This is the sprint's **revert switch**: no HUD change here is provable off
     *  a car, so a tester must be able to get back to today's proven bytes by
     *  flipping a setting, with no rebuild. Set this to `ui7` and the transport
     *  speaks exactly what we ship today regardless of what the per-model default
     *  becomes. See [SomeIpVariants] for the resolution rule. */
    @Volatile var someIpVariant: String = SomeIpVariants.AUTO
        private set

    /** The variant actually in force = model-derived default, unless [someIpVariant]
     *  overrides it. Resolves to [SomeIpVariants.UI7] on every path, including an
     *  undetected car. This is the ONE read point — the transport's
     *  [com.i99dev.ilink.nav.transport.someip.SelectedSomeIpVariant] calls it and
     *  nothing else does, so the flag stays owned by its component. */
    val resolvedSomeIpVariant: String
        get() = SomeIpVariants.resolve(someIpVariant, modelName)

    /** Cached friendly model name from the EXISTING detector, read once in [init].
     *  Null until init / on an unrecognised car — which resolves to `ui7` anyway. */
    @Volatile private var modelName: String? = null

    /** Read-only view of the detected model, for the variant factory's per-model
     *  tables (e.g. `LauncherMapPose.forModel`). Exposed rather than re-probed so
     *  the detector is still read exactly once, in [init]. */
    val detectedModelName: String? get() = modelName

    private const val PREFS = "nav_hud_options"

    @Volatile private var prefs: android.content.SharedPreferences? = null

    /** Load persisted values once. Idempotent — safe to call on every plugin build. */
    fun init(context: Context) {
        val p = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs = p
        transliterate = p.getBoolean("transliterate", transliterate)
        cameraAlerts = p.getBoolean("cameraAlerts", cameraAlerts)
        amapWidget = p.getBoolean("amapWidget", amapWidget)
        autoStart = p.getBoolean("autoStart", autoStart)
        clusterProtocol = p.getString("clusterProtocol", clusterProtocol) ?: "auto"
        // Sanitise on load: a build that once offered an extra variant leaves its
        // id behind after a rollback. Falling back to `auto` (⇒ the proven wire)
        // is the safe read, and it also means a corrupted pref can never brick
        // the HUD.
        someIpVariant = (p.getString("someIpVariant", someIpVariant) ?: SomeIpVariants.AUTO)
            .takeIf { SomeIpVariants.isKnown(it) } ?: SomeIpVariants.AUTO
        hudEnabled = p.getBoolean("hudEnabled", hudEnabled)
        // Model comes from the EXISTING detector (system properties only — no
        // shell round-trip, so this stays cheap enough for plugin construction).
        // Best-effort: a failure just leaves the conservative `ui7` default.
        modelName = runCatching { com.i99dev.ilink.car.CarIdentity.modelName() }.getOrNull()
    }

    /** Persist the master HUD on/off. Set by arm()/disarm() so the choice survives
     *  restarts and the plugin can auto-arm on next launch. */
    fun setHudEnabled(value: Boolean) {
        hudEnabled = value
        prefs?.edit()?.putBoolean("hudEnabled", value)?.apply()
    }

    /** Set the cluster-protocol override. Ignores unknown values (stays put). */
    fun setClusterProtocol(value: String) {
        if (value != "auto" && value != "someip" && value != "canfid") return
        clusterProtocol = value
        prefs?.edit()?.putString("clusterProtocol", value)?.apply()
    }

    /** Set the SOME/IP variant override. Ignores unknown values (stays put) —
     *  same contract as [setClusterProtocol]. Takes effect on the next frame; the
     *  Dart controller re-arms so `start()`/`stop()` service ids stay paired. */
    fun setSomeIpVariant(value: String) {
        val v = value.trim().lowercase()
        if (!SomeIpVariants.isKnown(v)) return
        someIpVariant = v
        prefs?.edit()?.putString("someIpVariant", v)?.apply()
    }

    /** Test seam: inject the detected model instead of probing the device, so the
     *  resolution matrix can be host-tested against the REAL options object and
     *  not just against [SomeIpVariants] in isolation. Not called from app code. */
    fun setModelNameForTest(value: String?) {
        modelName = value
    }

    fun set(key: String, value: Boolean) {
        when (key) {
            "transliterate" -> transliterate = value
            "cameraAlerts" -> cameraAlerts = value
            "amapWidget" -> amapWidget = value
            "autoStart" -> autoStart = value
            else -> return
        }
        prefs?.edit()?.putBoolean(key, value)?.apply()
    }

    fun snapshot(): Map<String, Boolean> = mapOf(
        "transliterate" to transliterate,
        "cameraAlerts" to cameraAlerts,
        "amapWidget" to amapWidget,
        "autoStart" to autoStart,
    )
}

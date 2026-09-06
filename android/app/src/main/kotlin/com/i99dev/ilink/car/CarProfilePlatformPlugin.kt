package com.i99dev.ilink.car

import android.os.Build
import com.i99dev.ilink.miniapps.MiniAppDispatcher
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel that hands a fully-resolved [CarProfile] to the Dart
 * side in one call. Replaces the old `display.capabilityBits` path
 * (which only carried the bitmask) with the richer profile both
 * gates need:
 *   * Bitmask + readable capabilities for the catalog filter.
 *   * Action support for [CarCommandRouter]'s fast-deny shortcut.
 *   * `isFallback` + `fallbackReason` for the UI's "best-effort"
 *     hint and the Quick Report flow.
 *   * The full [ProfileKey] so Dart can attach it to probe + Quick
 *     Report POSTs without re-deriving on its own.
 *
 * Methods:
 *   * `snapshot()` — full CarProfile + actionSupport map.
 *   * `actionSupport({actionId})` — single-action fast lookup
 *     (saves a snapshot round-trip on per-dispatch checks).
 *
 * Hot path: `snapshot()` is called once at boot via the Dart
 * provider; `actionSupport` is called per CarCommandRouter dispatch.
 * Both are O(1) on the kotlin side — map lookups, no I/O.
 */
class CarProfilePlatformPlugin(
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "ilink/car_profile").also {
        it.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "snapshot" -> result.success(snapshot())
            "actionSupport" -> result.success(actionSupportFor(call))
            else -> result.notImplemented()
        }
    }

    private fun snapshot(): Map<String, Any?> {
        val key = activeProfileKey()
        val profile = CapabilityRegistry.resolve(key)
        // Per-action support classifications for every action listed
        // in [CarActionSupport]'s seed for this (variant, subTrim).
        // Dart caches this once at boot and consults the map
        // per-dispatch — no platform-channel hop on the hot path.
        val supportMap = serializeActionSupport(profile.key)
        return mapOf(
            "key" to profile.key.toMap(),
            "isFallback" to profile.isFallback,
            "fallbackReason" to profile.fallbackReason,
            "friendlyName" to profile.friendlyName,
            "capabilityBits" to profile.capabilityBits,
            "capabilities" to VehicleCapability.fromBits(profile.capabilityBits),
            "capabilitiesSource" to profile.capabilitiesSource,
            "actionSupport" to supportMap,
        )
    }

    private fun actionSupportFor(call: MethodCall): Map<String, Any?> {
        val actionId = call.argument<String>("actionId")
        if (actionId == null) {
            return mapOf("ok" to false, "error" to "actionId required")
        }
        val key = activeProfileKey()
        val support = CarActionSupport.supportFor(key, actionId)
        val cls = CarActionSupport.classOf(actionId)
        return mapOf(
            "ok" to true,
            "support" to support.name,
            "actionClass" to cls.name,
        )
    }

    /** Build the active [ProfileKey] from [CarIdentity] + the
     *  dispatcher's resolved variant. Stable per-process — the
     *  signals don't change without a reboot. */
    private fun activeProfileKey(): ProfileKey {
        val variantId = MiniAppDispatcher.activeModelIds().firstOrNull() ?: ""
        val subTrim = CarIdentity.resolveSubTrim()?.wire ?: ""
        val dilinkFamily = CarIdentity.resolveDilinkFamily()
        @Suppress("DEPRECATION")
        val fingerprint = Build.FINGERPRINT ?: ""
        return ProfileKey(
            dilinkFamily = dilinkFamily,
            variantId = variantId,
            subTrim = subTrim,
            fingerprint = fingerprint,
        )
    }

    /** Return one entry per *known* action — every BASIC, every
     *  CRITICAL, plus any ADVANCED action the seed has an explicit
     *  entry for. ADVANCED actions outside the seed default to
     *  UNKNOWN_ASSUME_SUPPORTED on the Dart side, so the map stays
     *  small. */
    private fun serializeActionSupport(key: ProfileKey): Map<String, String> {
        val out = mutableMapOf<String, String>()
        // The action classifier is reachable enum-style; here we
        // just enumerate the known seed entries plus the basic /
        // critical sets so Dart's per-dispatch lookup can answer
        // without crossing the channel.
        val knownActions = KNOWN_ACTIONS_FOR_SERIALIZATION
        for (action in knownActions) {
            val support = CarActionSupport.supportFor(key, action)
            out[action] = support.name
        }
        return out
    }

    companion object {
        /** Conservative list of action ids the snapshot serialises.
         *  Keep small (<50) — Dart's local cache mirrors this list,
         *  so growth here costs every catalog snapshot byte-wise.
         *  Anything not listed defaults to UNKNOWN_ASSUME_SUPPORTED
         *  on the Dart side. */
        private val KNOWN_ACTIONS_FOR_SERIALIZATION = listOf(
            // BASIC
            "lock_door",
            "unlock_door",
            "set_ac_power",
            "set_ac_fan_speed",
            "set_ac_temperature",
            "set_window_position",
            // CRITICAL
            "set_sunroof",
            "fold_mirrors",
            "open_hood",
            "open_trunk_motor",
            // ADVANCED with seed entries
            "set_seat_massage",
            "set_seat_heat",
            "set_hud_brightness",
        )
    }
}

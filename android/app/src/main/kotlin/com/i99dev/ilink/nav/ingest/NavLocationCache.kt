package com.i99dev.ilink.nav.ingest

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.SystemClock
import com.i99dev.ilink.nav.domain.NavFix

/**
 * The ONE place the nav stack learns where the car is. Reads the last known fix
 * and hands back a pure [NavFix]; every [NavSource] stays location-free (position
 * is stamped once at the ingest boundary — see [NavSourceRegistry]).
 *
 * Three rules, all of them load-bearing:
 *  - **Throttled**: at most one real provider read every [throttleMs] (5 s,
 *    mirroring the reference). Frames arrive at ~5 Hz from a11y; the cluster does
 *    not need 5 Hz of position, and `getLastKnownLocation` is a binder call.
 *  - **Permission-checked**: we may not hold ACCESS_*_LOCATION on every car. No
 *    permission → [current] returns null forever, silently, no throw.
 *  - **Fail-quiet**: no fix, disabled provider, or a SecurityException from a
 *    vendor-hardened ROM all return null. A null position must leave downstream
 *    behaviour exactly as it is today.
 *
 * The [reader] and [nowMs] seams exist so the throttle is host-testable with zero
 * Android; production wiring goes through [forContext].
 */
class NavLocationCache(
    /** Does the actual (expensive, platform) read. Returns null when unavailable. */
    private val reader: () -> NavFix?,
    /** Monotonic clock, milliseconds. INJECTABLE so the throttle is host-testable. */
    private val nowMs: () -> Long,
    /** Minimum interval between two real [reader] invocations. */
    private val throttleMs: Long = THROTTLE_MS,
) {
    @Volatile private var cached: NavFix? = null
    @Volatile private var lastReadAtMs: Long = Long.MIN_VALUE

    /**
     * The freshest position we are willing to pay for, or null when there is no
     * fix / no permission. Cheap and safe to call on every ingested frame: at most
     * one real read per [throttleMs], the rest are served from cache.
     */
    fun current(): NavFix? {
        val now = nowMs()
        // Long.MIN_VALUE start would overflow on subtraction — compare additively.
        val due = lastReadAtMs == Long.MIN_VALUE || now - lastReadAtMs >= throttleMs
        if (due) {
            lastReadAtMs = now
            // Keep the previous fix if this read came back empty: a momentary
            // provider gap should not blank a position we already had.
            runCatching { reader() }.getOrNull()?.let { cached = it }
        }
        return cached
    }

    /** Drop all state — call on HUD disarm so a re-arm re-reads immediately. */
    fun reset() {
        cached = null
        lastReadAtMs = Long.MIN_VALUE
    }

    companion object {
        /** Reference behaviour: refresh the position at most every 5 s. */
        const val THROTTLE_MS = 5_000L

        /** GPS first (accurate + carries a bearing), network as fallback. */
        private val PROVIDERS = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)

        /**
         * Production wiring. Safe to build even when the permission is missing —
         * the returned cache then simply always yields null.
         */
        fun forContext(context: Context): NavLocationCache {
            val app = context.applicationContext
            return NavLocationCache(
                reader = { readLastKnown(app) },
                nowMs = { SystemClock.elapsedRealtime() },
            )
        }

        /** True only if we actually hold a location permission RIGHT NOW. Checked on
         *  every read, not once at construction: the user can grant it later and the
         *  HUD should start carrying position without an app restart. */
        fun hasPermission(context: Context): Boolean =
            context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED ||
                context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
                    PackageManager.PERMISSION_GRANTED

        private fun readLastKnown(context: Context): NavFix? {
            if (!hasPermission(context)) return null
            val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return null
            for (provider in PROVIDERS) {
                val loc = runCatching { lm.getLastKnownLocation(provider) }.getOrNull() ?: continue
                val fix = NavFix(
                    lat = loc.latitude,
                    lon = loc.longitude,
                    heading = if (loc.hasBearing()) loc.bearing.toDouble() else null,
                )
                if (fix.isPlausible) return fix
            }
            return null
        }
    }
}

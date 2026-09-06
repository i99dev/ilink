package com.i99dev.ilink.location

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel

/**
 * Streams real GPS fixes from Android's ``LocationManager`` so the
 * Flutter side gets continuous updates that actually engage the GNSS
 * chip on the BYD head unit.
 *
 * Why we need this even though Flutter has the ``geolocator``
 * package: on this OEM, geolocator's
 * ``AndroidSettings(forceLocationManager: true)`` option is silently
 * ignored — the plugin always routes through
 * ``FusedLocationProviderClient``, and Fused on the BYD HU does not
 * escalate our request to the underlying GNSS provider. ``dumpsys
 * location`` proves it: with geolocator alone we appear under
 * ``fused provider`` listeners but never under ``gps provider``,
 * and the chip never wakes. With this bridge we register directly
 * with LocationManager → we appear in ``gps provider`` listeners
 * alongside Waze / Huawei Maps / AMap (which all take the same
 * path), and the chip starts emitting fresh fixes.
 *
 * One bridge per app process. ``MainActivity.configureFlutterEngine``
 * registers the EventChannel; the Dart side reads via
 * ``EventChannel('ilink/location/stream').receiveBroadcastStream()``
 * and feeds every fix into ``LocationService._lastStreamFix`` so
 * voice's ``freshFix()`` always has a sub-5-second-old position.
 */
class LocationBridge(private val context: Context) : EventChannel.StreamHandler {

    companion object {
        private const val TAG = "LocationBridge"

        /// Wire-format keys used by the Dart side; matches the
        /// original LocationBridge.kt removed Apr 2026 with the map
        /// screen, so a future re-introduction of a map widget can
        /// share this channel without renaming.
        const val CHANNEL_NAME = "ilink/location/stream"
    }

    private val lm: LocationManager =
        context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private var sink: EventChannel.EventSink? = null

    private val listener = object : LocationListener {
        override fun onLocationChanged(loc: Location) = emit(loc)
        override fun onProviderEnabled(provider: String) { emitAccessState() }
        override fun onProviderDisabled(provider: String) { emitAccessState() }
        @Deprecated("Kept for API level compatibility")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    }

    @SuppressLint("MissingPermission")
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (!hasPermission()) {
            emitAccessState(); return
        }
        // Seed with last-known so the UI doesn't blink "no fix" while
        // we wait for the first live update — but only when it's
        // recent enough to be useful. The OS's last-known can be
        // multi-day-old on a parked car (we hit a Kazakhstan-cached
        // value from 2 days ago in production), so we filter by
        // staleness; the Dart side has its own freshness check too.
        // Prefer the raw chip's last-known (gps), then network, then fused.
        for (provider in listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.FUSED_PROVIDER,
        )) {
            try {
                val last = lm.getLastKnownLocation(provider) ?: continue
                emit(last); break
            } catch (_: Throwable) {}
        }
        // Bind the RAW chip directly (gps provider), NOT the ROM's fused
        // proxy. This is one APK across the whole fleet, and fused is not
        // uniform: on some BYD ROMs (e.g. Leopard 8) fused does reach the
        // GNSS chip, but on others it's a dead source that never escalates
        // to the chip — so trusting fused makes "nearby" work on some cars
        // and silently fail on others with identical code. The gps provider
        // is the universal raw-chip path Waze / AMap take. We subscribe to
        // gps AND network (coarse seed + fallback while the chip locks);
        // fused is a last resort only if neither is enabled.
        try {
            val subscribed = mutableListOf<String>()
            for (provider in listOf(
                LocationManager.GPS_PROVIDER,
                LocationManager.NETWORK_PROVIDER,
            )) {
                if (lm.isProviderEnabled(provider)) {
                    lm.requestLocationUpdates(
                        provider,
                        /* minTimeMs */ 1_000L,
                        /* minDistanceM */ 0f,
                        listener,
                        Looper.getMainLooper(),
                    )
                    subscribed += provider
                }
            }
            if (subscribed.isEmpty() &&
                lm.getProviders(true).contains(LocationManager.FUSED_PROVIDER)
            ) {
                lm.requestLocationUpdates(
                    LocationManager.FUSED_PROVIDER,
                    1_000L,
                    0f,
                    listener,
                    Looper.getMainLooper(),
                )
                subscribed += LocationManager.FUSED_PROVIDER
            }
            if (subscribed.isEmpty()) {
                Log.w(TAG, "no location provider enabled")
                emitAccessState()
            } else {
                Log.i(TAG, "subscribed to ${subscribed.joinToString("+")}")
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "requestLocationUpdates denied: ${e.message}")
            emitAccessState()
        }
    }

    override fun onCancel(arguments: Any?) {
        try { lm.removeUpdates(listener) } catch (_: Throwable) {}
        sink = null
    }

    fun hasPermission(): Boolean = ContextCompat.checkSelfPermission(
        context, Manifest.permission.ACCESS_FINE_LOCATION,
    ) == PackageManager.PERMISSION_GRANTED || ContextCompat.checkSelfPermission(
        context, Manifest.permission.ACCESS_COARSE_LOCATION,
    ) == PackageManager.PERMISSION_GRANTED

    private fun emit(loc: Location) {
        sink?.success(mapOf(
            "ok" to true,
            "lat" to loc.latitude,
            "lng" to loc.longitude,
            "accuracyM" to if (loc.hasAccuracy()) loc.accuracy else null,
            "altitudeM" to if (loc.hasAltitude()) loc.altitude else null,
            "bearingDeg" to if (loc.hasBearing()) loc.bearing else null,
            "speedMps" to if (loc.hasSpeed()) loc.speed else null,
            "provider" to loc.provider,
            "timeMs" to loc.time,
        ))
    }

    private fun emitAccessState() {
        sink?.success(mapOf(
            "ok" to false,
            "reason" to if (hasPermission()) "no_fix" else "no_permission",
        ))
    }
}

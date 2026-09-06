package com.i99dev.ilink.nav.logic

import com.i99dev.ilink.nav.domain.NavGuidance
import kotlin.math.abs

/**
 * Decides whether a frame is worth pushing to the cluster, so the SOME/IP /
 * HAL hot path only fires on a *meaningful* change. Stateful (single-producer
 * on the nav-hud thread → lock-free).
 *
 * Two jobs, both from the plan's perf rules:
 *  - **Per-field dedup**: skip if nothing the cluster shows changed. `source`
 *    and the rolling counter are METADATA — excluded from the comparison
 *    (a source flap with identical content must not re-push).
 *  - **Distance quantization**: distance counts down every metre while driving
 *    (~5 Hz from a11y), but the cluster shows buckets ("250 m", not "247 m").
 *    Only a bucket change counts — this is what keeps the hot path off the
 *    a11y read rate.
 *
 * [keyframe] forces a push regardless (arm / winner-change / transport
 * reconnect) so the cluster never shows a half-built frame after a gap.
 */
class NavGuidanceCoalescer(
    /** Distance display granularity in metres (cluster shows ~this bucket). */
    private val distanceBucketMeters: Int = 50,
) {
    private var last: NavGuidance? = null

    /** @return the frame to push, or null to skip. Updates state on a push. */
    fun next(frame: NavGuidance, keyframe: Boolean = false): NavGuidance? {
        val prev = last
        if (!keyframe && prev != null && !changed(prev, frame)) return null
        last = frame
        return frame
    }

    /** Drop all state — call on stop / transport loss so the next frame is a keyframe. */
    fun reset() {
        last = null
    }

    private fun changed(a: NavGuidance, b: NavGuidance): Boolean =
        a.maneuverIcon != b.maneuverIcon ||
            a.roadName != b.roadName ||
            a.secondaryRoadName != b.secondaryRoadName ||
            maneuverBucket(a.distanceMeters) != maneuverBucket(b.distanceMeters) ||
            // remaining distance/time only matter at a coarse bucket too
            bucket(a.remainingDistanceMeters, 100) != bucket(b.remainingDistanceMeters, 100) ||
            timeBucket(a.remainingTimeSeconds) != timeBucket(b.remainingTimeSeconds) ||
            a.lane != b.lane ||
            a.cameraType != b.cameraType || a.cameraState != b.cameraState ||
            a.safetyType != b.safetyType || a.safetyState != b.safetyState ||
            a.trafficLightColor != b.trafficLightColor ||
            a.trafficLightSeconds != b.trafficLightSeconds
    // NOTE: a.source / counter intentionally NOT compared.
    // NOTE: lat/lon/heading are intentionally NOT compared either. Position is
    // METADATA that rides along on whatever frame is already being pushed — a
    // drifting GPS coordinate must never, on its own, push to the cluster (a fix
    // updates continuously while parked, which would be a push storm on the
    // SOME/IP / HAL hot path). `changed()` is an explicit allow-list, so any new
    // NavGuidance field is excluded until it is deliberately added here.

    private fun bucket(d: Int?, size: Int = distanceBucketMeters): Int? =
        d?.let { if (it < 0) -1 else it / size }

    /** Maneuver-distance bucket: fine when close (the countdown the driver reads),
     *  coarse far away (keeps the hot path off the ~5 Hz a11y read rate). The
     *  boundary sizes only widen with distance, so it never flickers. This is the
     *  anti-lag fix — at 150 m the cluster now updates every 10 m, not every 50 m. */
    private fun maneuverBucket(d: Int?): Int? = d?.let {
        when {
            it < 0 -> -1
            it < 200 -> it / 10 // 10 m steps inside 200 m (smooth final countdown)
            it < 600 -> it / 25 // 25 m steps mid-range
            else -> it / 50 // 50 m steps far out
        }
    }

    /** Remaining-time bucket: 1-min granularity (the cluster shows whole min). */
    private fun timeBucket(s: Int?): Int? = s?.let { if (it < 0) -1 else it / 60 }

    @Suppress("unused")
    private fun near(a: Int?, b: Int?, tol: Int): Boolean =
        (a == null && b == null) || (a != null && b != null && abs(a - b) <= tol)
}

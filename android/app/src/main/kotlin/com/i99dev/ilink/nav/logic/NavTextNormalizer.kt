package com.i99dev.ilink.nav.logic

import com.i99dev.ilink.nav.domain.NavGuidance

/**
 * The single, pure text-normalization step for outgoing guidance. Folds the
 * frame's road names to Latin-ASCII (via [HudTextSanitizer]) so the cluster's
 * Latin-only widgets render cleanly, regardless of which source produced them.
 *
 * Lives here (not in a transport or a source) so EVERY transport and the
 * controller's keepalive share one implementation — applied exactly once, at the
 * controller choke point, before the frame is cached. Pure + host-testable; the
 * ICU transliteration itself is Android-only (host falls back to NFD stripping).
 */
object NavTextNormalizer {

    /** Returns a frame whose [NavGuidance.roadName] / [NavGuidance.secondaryRoadName]
     *  are folded to ASCII when [enabled]; the SAME instance when disabled or when
     *  nothing changed (no needless allocation on the hot path). */
    fun apply(frame: NavGuidance, enabled: Boolean): NavGuidance {
        if (!enabled) return frame
        val road = HudTextSanitizer.sanitize(frame.roadName)
        val secondary = HudTextSanitizer.sanitize(frame.secondaryRoadName)
        return if (road == frame.roadName && secondary == frame.secondaryRoadName) frame
        else frame.copy(roadName = road, secondaryRoadName = secondary)
    }
}

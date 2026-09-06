package com.i99dev.ilink.display

import android.content.Context
import android.hardware.display.DisplayManager

/**
 * Resolves a requested logical displayId to the surface displayId
 * where the OS routes input and overlay windows.
 *
 * On BYD's XDJA-virtualized cluster
 * (Leopard 8 / FangChengBao 8 / Yangwang U8 / Denza N7 — every
 * platform that ships the XDJA composer), the
 * `shared_fission_bg_XDJAScreenProjection_*` displays (ids 4, 5)
 * are launch-only targets: ActivityManager places activities on
 * them, but their visible content is composited onto the base
 * `fission_bg_XDJAScreenProjection` display (id 3). InputDispatcher
 * follows the surface — `dumpsys input` after a cluster launch
 * shows `displayId=3` for the launched window. So
 * `gesture.dispatch(displayId=5)` reaches no window; the OS needs
 * the dispatch on display 3 to actually deliver to the launched app.
 *
 * Mini-apps shouldn't have to know any of this. They use one id
 * for launch + cursor + gesture; the host re-routes input ops
 * silently to the surface display.
 *
 * No cache: callers are gesture handlers that fire at most a few
 * Hz during user interaction (one tap = one resolve), so the cost
 * of `DisplayManager.getDisplays()` per call is irrelevant and
 * we sidestep all hot-plug invalidation concerns. cursor.move
 * doesn't go through here — it's on its own channel.
 */
class DisplayInputResolver(applicationContext: Context) {

    private val displayMgr: DisplayManager =
        applicationContext.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager

    /**
     * Resolve [requestedDisplayId] to the surface display where
     * input + overlay windows land. Returns the input id unchanged
     * when no remapping applies (default case on non-XDJA cars).
     */
    fun resolve(requestedDisplayId: Int): Int {
        val displays = displayMgr.displays
        // We only remap when the request is for a shared overlay
        // slot. The early return short-circuits the IVI / passenger
        // / unknown / non-XDJA cases without scanning the array.
        val requested = displays.firstOrNull { it.displayId == requestedDisplayId }
            ?: return requestedDisplayId
        if (!SHARED_RE.matches(requested.name.orEmpty())) {
            return requestedDisplayId
        }
        // The base XDJA cluster display: name matches `fission_bg_*`
        // but NOT `shared_fission_bg_*`. That's the surface every
        // shared overlay composites onto.
        val base = displays.firstOrNull { d ->
            val n = d.name.orEmpty()
            BASE_RE.matches(n) && !SHARED_RE.matches(n)
        }
        return base?.displayId ?: requestedDisplayId
    }

    companion object {
        // Base cluster slot, e.g. "fission_bg_XDJAScreenProjection".
        private val BASE_RE = Regex("^fission_bg_.*", RegexOption.IGNORE_CASE)

        // Overlay slots, e.g. "shared_fission_bg_XDJAScreenProjection_0"
        // / "shared_fission_bg_XDJAScreenProjection_1". Trailing `_<n>`
        // suffix differentiates them from the base.
        private val SHARED_RE = Regex(
            "^shared_fission_bg_.*_\\d+$",
            RegexOption.IGNORE_CASE,
        )
    }
}

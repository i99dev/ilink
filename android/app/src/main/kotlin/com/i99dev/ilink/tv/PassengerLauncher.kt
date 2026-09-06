package com.i99dev.ilink.tv

import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import com.i99dev.ilink.display.DisplayRoles
import com.i99dev.ilink.pkg.AmShellResult
import com.i99dev.ilink.pkg.AmShellRunner

/**
 * Shared passenger-display cast launch, used by both [TvPassengerPlugin]
 * (Flutter) and the native [TvIviPlayerActivity] cast button. Launches
 * [PassengerPlayerActivity] on the FSE display over loopback ADB — the
 * only path a non-system app can pin a launch to a non-default display.
 *
 * [cast] BLOCKS on the loopback-ADB bridge, so callers must run it off the
 * main thread.
 */
object PassengerLauncher {
    private const val COMPONENT = "com.i99dev.ilink/.tv.PassengerPlayerActivity"
    private const val LAUNCH_TIMEOUT_MS = 8_000L

    /** The enumerated passenger display id, or null if none is reachable
     *  via the framework (Di5.0 BYD-container synthetic FSE). */
    fun passengerDisplayId(context: Context): Int? {
        val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        return dm.displays
            .firstOrNull { DisplayRoles.roleFor(it) == DisplayRoles.PASSENGER }
            ?.displayId
    }

    /** Launch (or re-cast) [url] on the passenger display. Returns
     *  `(ok, error?)`. Off-main only. */
    fun cast(
        context: Context,
        url: String,
        title: String,
        referer: String?,
        userAgent: String?,
        maxBitrate: Int,
    ): Pair<Boolean, String?> {
        if (!StreamingPolicy.canPlay(context, url)) return false to "streaming disabled"
        val displayId = passengerDisplayId(context) ?: return false to "no passenger display"
        val cmd = buildAmStart(displayId, url, title, referer, userAgent, maxBitrate)
        return when (
            val r = AmShellRunner.runWithRetry(
                cmd = cmd,
                timeoutMs = LAUNCH_TIMEOUT_MS,
                maxRetries = AmShellRunner.DEFAULT_MAX_RETRIES,
            )
        ) {
            is AmShellResult.Ok -> true to null
            is AmShellResult.WmsTransient -> false to "wms_transient"
            is AmShellResult.HardFailure -> false to r.reason
        }
    }

    /** Stop the passenger player (same-app cross-process broadcast). */
    fun stop(context: Context, networkOnly: Boolean = false) {
        context.sendBroadcast(
            Intent(PassengerPlayerActivity.ACTION_STOP)
                .setPackage(context.packageName)
                .putExtra("networkOnly", networkOnly),
        )
    }

    private fun buildAmStart(
        displayId: Int,
        url: String,
        title: String,
        referer: String?,
        userAgent: String?,
        maxBitrate: Int,
    ): String = buildString {
        append("am start-activity --display ").append(displayId)
        append(" -n ").append(COMPONENT)
        append(" --es ").append(PassengerPlayerActivity.EXTRA_URL).append(' ').append(sq(url))
        append(" --es ").append(PassengerPlayerActivity.EXTRA_TITLE).append(' ').append(sq(title))
        if (!referer.isNullOrBlank()) {
            append(" --es ").append(PassengerPlayerActivity.EXTRA_REFERER).append(' ').append(sq(referer))
        }
        if (!userAgent.isNullOrBlank()) {
            append(" --es ").append(PassengerPlayerActivity.EXTRA_USER_AGENT).append(' ').append(sq(userAgent))
        }
        if (maxBitrate > 0) {
            append(" --ei ").append(PassengerPlayerActivity.EXTRA_MAX_BITRATE).append(' ').append(maxBitrate)
        }
    }

    /** Single-quote for the shell, escaping embedded single quotes. */
    private fun sq(s: String): String = "'" + s.replace("'", "'\\''") + "'"
}

package com.i99dev.ilink.pkg

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.i99dev.ilink.adb.AdbShellBridge
import java.util.concurrent.Executors

/**
 * Auto-dismiss watcher for dialogs on cluster displays.
 *
 * Driver attention is precious — a dialog popping up on the cluster
 * (ReVanced first-run nag, "Sign in to continue", "App stopped"
 * crash dialog, OS permission prompts) takes their eyes off the
 * road. This watcher polls the cluster's input window list and, on
 * detecting anything matching dialog heuristics, injects
 * `KEYCODE_BACK` on that display to dismiss it. The operator-
 * approved cluster app stays foregrounded; the transient dialog
 * goes away within ~1.5 s of appearing.
 *
 * Trade-off: aggressive. A legitimate "are you sure?" confirmation
 * an app on the cluster wanted the user to see WILL be auto-
 * dismissed (the BACK keyevent treats it like a cancel). Operator-
 * accepted per the design discussion 2026-05-20 — see the
 * `cluster-fullscreen-disable-pip` branch.
 *
 * Detection heuristic (intentionally loose): any window whose
 * activity class name contains "Dialog" or "Alert" on a cluster
 * candidate display (3 or 4 — covers Di5.1/XDJA + Di5.0/BYD
 * cluster IDs). The check runs against the (filtered) `dumpsys
 * input` output.
 *
 * Lifecycle: started at [PackagePlatformPlugin] init,
 * [stop]ped at plugin destroy. Polls on a single-thread executor
 * (NOT the main thread — `AdbShellBridge.shell` is blocking) and
 * reposts itself every [POLL_MS]. Stop is idempotent.
 */
object ClusterDialogWatcher {
    private const val TAG = "ClusterDialogWatcher"

    /** Poll cadence. 1.5 s is the same cushion the cluster cursor
     *  throttle uses + roughly the time a dialog needs to be
     *  visible enough to register as "dismissible." Tighter polling
     *  is wasted; looser leaves the dialog up too long. */
    private const val POLL_MS = 1_500L

    /** Cluster candidate displays. On Di5.1/XDJA the input window
     *  lives on 3; on Di5.0/BYD the driver cluster's input target is
     *  4. We poll BOTH on every trim — windows on the "wrong" one
     *  match nothing and cost us a regex scan, the cost is trivial,
     *  and the alternative (probing the active profile every tick)
     *  is extra plumbing for the same effect. */
    private val CLUSTER_DISPLAYS = listOf(3, 4)

    /** Activity-name regex. Matches anything containing `dialog` or
     *  `alert` (case-insensitive). False positives are acceptable
     *  by design — see KDoc. */
    private val DIALOG_PATTERN = Regex("(?i)dialog|alert")

    @Volatile private var running = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "cluster-dialog-watcher").apply { isDaemon = true }
    }

    fun start() {
        if (running) return
        running = true
        Log.i(TAG, "ClusterDialogWatcher: started")
        schedule()
    }

    fun stop() {
        running = false
        Log.i(TAG, "ClusterDialogWatcher: stopped")
    }

    private fun schedule() {
        if (!running) return
        mainHandler.postDelayed({
            if (!running) return@postDelayed
            executor.execute(::tick)
        }, POLL_MS)
    }

    private fun tick() {
        if (!running) return
        try {
            for (displayId in CLUSTER_DISPLAYS) {
                if (!running) return
                val out = AdbShellBridge.shell(
                    "dumpsys input | grep \"displayId=$displayId\"",
                    4_000L,
                )
                if (out.isEmpty()) continue
                // Look for any line containing a dialog-y activity
                // class name. The line shape is
                // `name='<hex> <pkg>/<activity>' …` per
                // `dumpsys input` window list — same surface the
                // cluster resolver parses, but we only need the
                // name token here.
                val matched = out.lineSequence().firstOrNull { line ->
                    DIALOG_PATTERN.containsMatchIn(line)
                } ?: continue
                Log.i(
                    TAG,
                    "ClusterDialogWatcher: dialog on display $displayId → " +
                        "BACK ($matched)",
                )
                AdbShellBridge.shell(
                    "input -d $displayId keyevent KEYCODE_BACK",
                    4_000L,
                )
            }
        } catch (t: Throwable) {
            Log.w(TAG, "tick failed: ${t.javaClass.simpleName}: ${t.message}")
        } finally {
            schedule()
        }
    }
}

package com.i99dev.ilink.clusterpatch

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * DEBUG-ONLY E2E trigger for the cluster patcher. Lets the patch path be
 * driven from adb without tapping through the Flutter UI:
 *
 * ```
 * adb shell am broadcast \
 *   -n com.i99dev.ilink/.clusterpatch.ClusterPatchDebugReceiver \
 *   --es pkg <packageName>
 * ```
 *
 * The outcome is logged under tag `ClusterPatchDebug`. This class lives in
 * `src/debug/` and the manifest entry in `src/debug/AndroidManifest.xml`,
 * so it is merged into debug builds only and is absent from release.
 */
class ClusterPatchDebugReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pkg = intent.getStringExtra("pkg")
        if (pkg.isNullOrBlank()) {
            Log.e(TAG, "missing --es pkg <packageName>")
            return
        }
        val action = intent.getStringExtra("action") ?: "patch"
        val app = context.applicationContext
        // goAsync keeps the receiver alive while the (slow) op runs off the
        // main thread.
        val pending = goAsync()
        Thread {
            try {
                val outcome = if (action == "unpatch") {
                    ClusterPatchService.unpatch(app, pkg)
                } else {
                    ClusterPatchService.patchAndInstall(app, pkg)
                }
                Log.i(TAG, "RESULT action=$action pkg=$pkg outcome=$outcome")
            } catch (t: Throwable) {
                Log.e(TAG, "RESULT action=$action pkg=$pkg threw: ${t.message}", t)
            } finally {
                pending.finish()
            }
        }.start()
    }

    companion object {
        private const val TAG = "ClusterPatchDebug"
    }
}

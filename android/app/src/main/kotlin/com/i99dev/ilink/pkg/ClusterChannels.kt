package com.i99dev.ilink.pkg

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.i99dev.ilink.car.profiles.CarProfile
import com.i99dev.ilink.miniapps.MiniAppShellCommands
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService

/**
 * Cluster-pad channel ops extracted from [PackagePlatformPlugin]: the
 * fresh-launch-only policy CRUD, the IVI-trackpad input resolve/inject,
 * the cluster-side cursor overlay, and the cluster-surface clear.
 *
 * These are bodies moved verbatim — no logic change — so behaviour is
 * preserved by construction. They share the plugin's single-thread
 * [adbExecutor] (shell I/O) and read the active [CarProfile] through the
 * [activeProfile] lambda (the trim topology — cursor remap, hidden layers
 * — is resolved the same way the launch/move web does; that resolution
 * stays in the plugin and is handed in here).
 *
 * NB: this is on-car-tested, multi-trim cluster-pad logic (L8 / L5 / Song
 * Plus). The extraction is mechanical; the BEHAVIOUR must be re-verified
 * on each trim before shipping.
 */
class ClusterChannels(
    private val context: Context,
    private val adbExecutor: ExecutorService,
    private val activeProfile: () -> CarProfile,
) {

    // ── Fresh-launch-only policy ([ClusterLaunchPolicy]) ──
    // Thin CRUD only — all logic lives in the policy object. Cheap +
    // synchronous (no adbExecutor): a prefs read / map filter.

    fun policyList(): Map<String, Any?> =
        mapOf("added" to ClusterLaunchPolicy.userAdded(context).toList())

    fun policyClassify(call: MethodCall): Map<String, Any?> {
        val pkgs = call.argument<List<String>>("packages") ?: emptyList()
        return mapOf(
            "freshLaunchOnly" to ClusterLaunchPolicy.freshLaunchSubset(pkgs),
        )
    }

    fun policyMutate(call: MethodCall, add: Boolean): Map<String, Any?> {
        val pkg = call.argument<String>("packageName")
            ?: return mapOf("ok" to false, "error" to "packageName required")
        val next =
            if (add) {
                ClusterLaunchPolicy.add(context, pkg)
            } else {
                ClusterLaunchPolicy.remove(context, pkg)
            }
        return mapOf("ok" to true, "added" to next.toList())
    }

    // ── Cluster cursor overlay ([ClusterCursorOverlay]) — the visible dot the
    // relative trackpad steers. A DISPLAY concern; synthetic input itself moved
    // to the centralized `ilink/gesture` seam (daemon injectInputEvent FAST
    // path), so the old `input -d N tap/swipe` forwarder is gone. ──

    fun cursorShow(call: MethodCall, result: MethodChannel.Result) {
        val d = call.argument<Int>("displayId")
        val w = call.argument<Int>("width")
        val h = call.argument<Int>("height")
        if (d == null || w == null || h == null) {
            result.success(mapOf("ok" to false, "error" to "displayId+w+h required"))
            return
        }
        val cursorDisplay = activeProfile().displays.cursorDisplayFor(d)
        ClusterCursorOverlay.show(context, cursorDisplay, w, h)
        result.success(mapOf("ok" to true, "cursorDisplayId" to cursorDisplay))
    }

    fun cursorMove(call: MethodCall, result: MethodChannel.Result) {
        val x = call.argument<Int>("x") ?: 0
        val y = call.argument<Int>("y") ?: 0
        ClusterCursorOverlay.move(x, y)
        result.success(mapOf("ok" to true))
    }

    fun cursorHide(result: MethodChannel.Result) {
        ClusterCursorOverlay.hide()
        result.success(mapOf("ok" to true))
    }

    /**
     * Clear the cluster surface — force-stops the leftover **non-system**
     * apps on the cluster displays and paints a black blank over each
     * display we actually cleared. Recovers the "leftover frame frozen
     * after move-back-to-IVI" symptom. Idempotent; off-main-thread.
     *
     * System / ROM packages are deliberately spared. The cluster
     * projection chain lives in system apps on these displays —
     * `com.example.amapservice` projects the cluster content,
     * `com.byd.cluster` + the XDJA container service host the surface,
     * and SystemUI owns the overlay. Force-stopping any of those tears
     * down the projection and leaves a black cluster the user can only
     * recover by restarting the car. This mirrors the `closeOtherApps`
     * doctor tool, which intersects with the non-system app list for the
     * same reason. We also blank only the displays where we removed a
     * non-system app — a display still owned by amap is left alone so we
     * don't fight its persistent (`persistent="true"`) re-projection.
     */
    fun clear(result: MethodChannel.Result) {
        adbExecutor.execute {
            try {
                val displays = activeProfile().displays
                val candidateDisplays = buildSet {
                    addAll(displays.hiddenDisplayIds)
                    if (displays.showCluster) {
                        addAll(displays.overrideLabels.keys.filter { it >= 3 })
                    }
                }.ifEmpty { setOf(3, 4, 5) }
                Log.i(
                    TAG,
                    "cluster.clear: candidate displays $candidateDisplays " +
                        "(profile-driven)",
                )
                val stackList = (
                    AmShellRunner.runOnce(
                        MiniAppShellCommands.amStackList(), 4_000L,
                    ) as? AmShellResult.Ok
                    )?.out ?: ""
                val snapshot = AmStackParser.parseAll(stackList)

                // Map display -> the non-system packages we'll evict, so
                // we can blank exactly the displays we cleared (and no
                // others). System apps — incl. the projection chain and
                // the launchers — are never killed.
                val killedByDisplay = mutableMapOf<Int, MutableSet<String>>()
                for (row in snapshot) {
                    if (row.displayId !in candidateDisplays) continue
                    val pkg = row.packageName
                    if (pkg == "com.i99dev.ilink" || isSystemApp(pkg)) continue
                    killedByDisplay.getOrPut(row.displayId) { mutableSetOf() }.add(pkg)
                }
                val toKill = killedByDisplay.values.flatten().toSet()
                for (pkg in toKill) {
                    AmShellRunner.runOnce("am force-stop $pkg", 4_000L)
                }
                val blanked = killedByDisplay.keys.toSortedSet()
                for (d in blanked) {
                    AmShellRunner.runOnce(
                        MiniAppShellCommands.amStartClusterBlank(d),
                        4_000L,
                    )
                }
                Handler(Looper.getMainLooper()).post {
                    result.success(
                        mapOf(
                            "ok" to true,
                            "cleared" to toKill.toList(),
                            "displays" to blanked.toList(),
                        ),
                    )
                }
            } catch (t: Throwable) {
                Log.w(TAG, "cluster.clear failed: ${t.message}")
                Handler(Looper.getMainLooper()).post {
                    result.success(mapOf("ok" to false, "error" to t.message))
                }
            }
        }
    }

    /**
     * True when [pkg] is a system / ROM app (carries `FLAG_SYSTEM`).
     * Unknown packages (PM can't resolve them) are treated as system so
     * `clear()` errs on the side of NOT force-stopping something it
     * can't identify. Same predicate as `PackageInventory.isSystemApp`.
     */
    private fun isSystemApp(pkg: String): Boolean = try {
        val info = context.packageManager.getApplicationInfo(pkg, 0)
        (info.flags and ApplicationInfo.FLAG_SYSTEM) != 0
    } catch (t: Throwable) {
        Log.w(TAG, "cluster.clear: cannot resolve $pkg, treating as system: ${t.message}")
        true
    }

    companion object {
        private const val TAG = "ClusterChannels"
    }
}

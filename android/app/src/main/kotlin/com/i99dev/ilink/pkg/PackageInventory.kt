package com.i99dev.ilink.pkg

import android.app.ActivityManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodCall

/**
 * Installed-package inventory + foreground/usage queries for the
 * `pkg.list` / `pkg.foreground` / `pkg.usage` ops.
 *
 * Extracted from [PackagePlatformPlugin]: pure PackageManager /
 * ActivityManager / UsageStatsManager reads, touches only [Context], and
 * shares no state with the launch / move-stack / cluster machinery.
 */
class PackageInventory(private val context: Context) {

    fun list(call: MethodCall): Map<String, Any?> {
        val includeSystem = call.argument<Boolean>("includeSystem") ?: false
        val pm = context.packageManager
        val launcherIntent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        // queryIntentActivities is the "launchable subset" filter —
        // every entry has at least one launcher activity. Cheaper
        // than getInstalledPackages + per-package launcher lookup,
        // and matches what an in-car launcher actually wants to show.
        @Suppress("DEPRECATION")
        val resolved = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.queryIntentActivities(
                launcherIntent,
                PackageManager.ResolveInfoFlags.of(0L),
            )
        } else {
            pm.queryIntentActivities(launcherIntent, 0)
        }

        val packages = resolved
            .distinctBy { it.activityInfo.applicationInfo.packageName }
            .filter { includeSystem || !it.activityInfo.applicationInfo.isSystemApp() }
            .mapNotNull { applicationInfoToMap(pm, it) }
            .sortedBy { (it["label"] as String).lowercase() }

        return mapOf("packages" to packages)
    }

    private fun applicationInfoToMap(
        pm: PackageManager,
        resolveInfo: ResolveInfo,
    ): Map<String, Any?>? {
        val info = resolveInfo.activityInfo.applicationInfo
        return try {
            val pkgInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(info.packageName, PackageManager.PackageInfoFlags.of(0L))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(info.packageName, 0)
            }
            val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pkgInfo.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                pkgInfo.versionCode.toLong()
            }
            // iconHash is a stable cache key — `pkg@versionCode`. Cheap to
            // compute (no icon render, no SHA), version-bumped naturally
            // invalidates a pinned entry on the SDK side. Render-and-encode
            // happens lazily when the SDK calls `pkg.icon` for an entry it
            // doesn't yet have cached (see PackageIconRenderer) — keeps
            // `pkg.list` fast on a 50-app device.
            mapOf(
                "packageName" to info.packageName,
                "label" to (pm.getApplicationLabel(info)?.toString() ?: info.packageName),
                "versionName" to (pkgInfo.versionName ?: ""),
                "versionCode" to versionCode,
                "isSystem" to info.isSystemApp(),
                "iconHash" to "${info.packageName}@${versionCode}",
            )
        } catch (e: PackageManager.NameNotFoundException) {
            null
        }
    }

    private fun ApplicationInfo.isSystemApp(): Boolean {
        return (flags and ApplicationInfo.FLAG_SYSTEM) != 0
    }

    fun foreground(): Map<String, Any?> {
        val now = System.currentTimeMillis()

        // Path 1 — cheap ActivityManager call. On vanilla post-API-21
        // this returns only our own task, but Leopard 8's vendor build
        // surfaces the foreground task to apps holding GET_TASKS in
        // the manifest (declared above). Worth trying first.
        runCatching {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            @Suppress("DEPRECATION")
            val tasks = am.getRunningTasks(1)
            val top = tasks.firstOrNull()?.topActivity
            if (top != null && top.packageName != context.packageName) {
                return mapOf(
                    "packageName" to top.packageName,
                    "activityClass" to top.flattenToShortString(),
                    "atMillis" to now,
                )
            }
        }

        // Path 2 — UsageStatsManager.queryUsageStats. Uses GET_USAGE_STATS
        // (PACKAGE_USAGE_STATS appop, granted by AdbBootstrap v5). 60s
        // window is enough to find the most-recent foreground entry
        // without inflating "totalTimeInForeground" (we only read
        // lastTimeUsed here).
        runCatching {
            val usm = context.getSystemService(Context.USAGE_STATS_SERVICE)
                as UsageStatsManager
            val end = now
            val start = end - 60_000L
            val rows = usm.queryUsageStats(UsageStatsManager.INTERVAL_BEST, start, end)
                ?: emptyList()
            val candidate = rows
                .filter { it.packageName != context.packageName }
                .maxByOrNull { it.lastTimeUsed }
            if (candidate != null && candidate.lastTimeUsed > 0) {
                return mapOf(
                    "packageName" to candidate.packageName,
                    "activityClass" to "",
                    "atMillis" to now,
                )
            }
        }

        // No-info canonical response. The Dart side reads `packageName`
        // == null as "host can't determine right now".
        return mapOf("packageName" to null, "activityClass" to "", "atMillis" to now)
    }

    fun usage(call: MethodCall): Map<String, Any?> {
        val windowMs = call.argument<Number>("windowMs")?.toLong()
            ?: return mapOf("rows" to emptyList<Any>(), "windowMs" to 0)
        return runCatching {
            val usm = context.getSystemService(Context.USAGE_STATS_SERVICE)
                as UsageStatsManager
            val end = System.currentTimeMillis()
            val start = end - windowMs
            val raw = usm.queryUsageStats(UsageStatsManager.INTERVAL_BEST, start, end)
                ?: emptyList()
            // queryUsageStats returns multiple rows per package over
            // a window (one per session). Roll up to per-package
            // totals so the SDK gets a single row each.
            val rolled = raw.groupBy { it.packageName }.map { (pkg, sessions) ->
                mapOf(
                    "packageName" to pkg,
                    "totalTimeInForegroundMs" to sessions
                        .sumOf { it.totalTimeInForeground },
                    "lastTimeUsedMs" to sessions
                        .maxOf { it.lastTimeUsed },
                )
            }.sortedByDescending { it["totalTimeInForegroundMs"] as Long }
            mapOf("rows" to rolled, "windowMs" to windowMs)
        }.getOrElse { e ->
            Log.w(TAG, "usage failed (likely no GET_USAGE_STATS appop): ${e.message}")
            mapOf("rows" to emptyList<Any>(), "windowMs" to windowMs)
        }
    }

    companion object {
        private const val TAG = "PackageInventory"
    }
}

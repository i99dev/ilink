package com.i99dev.ilink.launcher

import android.app.AppOpsManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Phase L1 — read-only launcher-mode privilege probe.
 *
 * MethodChannel `ilink/launcher_privilege` exposes one method:
 *
 *   * `status()` returns a flat map of every privilege ilink needs
 *     to operate as a viable BYD-launcher replacement. Each value is a
 *     boolean (granted / not granted). The Dart side renders this as a
 *     status grid in Settings → Diagnostics so the user can see which
 *     pieces are still missing before opting into launcher mode.
 *
 * Read-only by design — granting is a separate concern that lives in
 * the bootstrap dispatcher (Phase L2). Surfacing first means the user
 * gets visibility into HU state without committing to any UX choice
 * for the grant flow, and the developer has a baseline to compare
 * against after each model is on-boarded.
 *
 * Threading: every probe is cheap (PackageManager / Settings.Secure /
 * AppOpsManager / PowerManager lookups, no IO, no shell exec) so it
 * runs synchronously on the MethodChannel thread.
 */
class LauncherPrivilegePlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL)

    init {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "status" -> result.success(probe())
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            // Log the full stack so logcat triage has the throw site
            // even after Dart only sees the message. BYD's logcat
            // suppresses third-party app I-tags but keeps E-tags, so
            // these failures are visible in production triage.
            Log.e(TAG, "probe failed for ${call.method}", t)
            result.error(
                "LAUNCHER_PRIVILEGE_ERROR",
                t.message ?: "unknown",
                null,
            )
        }
    }

    private fun probe(): Map<String, Any> {
        val pm = context.packageManager
        val pkg = context.packageName
        return mapOf(
            // Regular permission grants. checkPermission returns
            // PERMISSION_GRANTED iff the perm has actually been granted
            // to this package — declaring it in the manifest alone is
            // not enough for privileged perms.
            //
            // MEDIA_CONTENT_CONTROL is intentionally NOT probed here:
            // it's signature|privileged on stock Android and `pm grant`
            // rejects it with ``not a changeable permission type``. The
            // music-aggregation feature uses NotificationListenerService
            // instead — see LauncherBootstrapPlugin.grantSpecs note.
            "writeSecureSettings" to perm(android.Manifest.permission.WRITE_SECURE_SETTINGS),
            "readLogs" to perm(android.Manifest.permission.READ_LOGS),

            // Special-access perms — checked via their dedicated APIs,
            // NOT via PackageManager.checkPermission (which always
            // returns DENIED for these even when granted).
            "packageUsageStats" to checkAppOpAllowed(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
            ),
            "systemAlertWindow" to Settings.canDrawOverlays(context),
            "ignoreBatteryOptimizations" to isBatteryUnrestricted(),

            // Component-level state. Distinct from perm grants — these
            // describe how the system has wired iLINK into the OS.
            "isDefaultHome" to isDefaultHome(pm, pkg),
            "remoteControlA11yEnabled" to isAccessibilityServiceEnabled(
                "$pkg/com.i99dev.ilink.input.RemoteControlAccessibilityService",
            ),
            "watchdogA11yEnabled" to isAccessibilityServiceEnabled(
                "$pkg/com.i99dev.ilink.input.WatchdogAccessibilityService",
            ),
            "homeAliasEnabled" to isHomeAliasEnabled(pm, pkg),
        )
    }

    private fun perm(name: String): Boolean {
        return context.checkPermission(
            name,
            Process.myPid(),
            Process.myUid(),
        ) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * AppOpsManager-backed permission probe. PACKAGE_USAGE_STATS and
     * friends live in the appop layer, not the perm layer — checking
     * via PackageManager.checkPermission would always return DENIED
     * even when the user has granted access through the system
     * Settings panel (or AdbBootstrap has flipped the appop).
     */
    private fun checkAppOpAllowed(op: String): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE)
            as? AppOpsManager ?: return false
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(op, Process.myUid(), context.packageName)
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(op, Process.myUid(), context.packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun isBatteryUnrestricted(): Boolean {
        val pm = context.getSystemService(Context.POWER_SERVICE)
            as? PowerManager ?: return false
        return pm.isIgnoringBatteryOptimizations(context.packageName)
    }

    /**
     * "Are we currently the system's resolved home activity?" Two
     * paths because PackageManager.getHomeActivities was the canonical
     * API on older builds but the resolveActivity path is the one the
     * system uses post-Android-12. We try both and return true if
     * either points at us.
     */
    private fun isDefaultHome(pm: PackageManager, pkg: String): Boolean {
        // Resolve the HOME intent and read the winning package.
        // PackageManager.getHomeActivities exists but is @hide on
        // most vendor builds (including Leopard 8) and would fail to
        // link at compile time outside the system class path. The
        // resolver path is public, works on every API level, and is
        // what the system itself uses to pick the home activity.
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val info = pm.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
        return info?.activityInfo?.packageName == pkg
    }

    /**
     * Reads the system's enabled-accessibility-services CSV directly
     * from Settings.Secure. AccessibilityManager.getEnabledAccessibilityServiceList
     * filters by feedback type which can hide services that the user
     * has turned on but the framework considers "stale"; the raw CSV
     * is the source of truth used by AdbBootstrap.
     */
    private fun isAccessibilityServiceEnabled(componentFlat: String): Boolean {
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        return enabled.split(':').any { it.equals(componentFlat, ignoreCase = false) }
    }

    /**
     * Whether the launcher-mode HOME alias is currently enabled in
     * PackageManager. Default-disabled in the manifest — flipped to
     * enabled when the user opts into launcher mode. Surfacing this
     * lets the Diagnostics view distinguish "user has not opted in"
     * from "opted in but missing perms".
     */
    private fun isHomeAliasEnabled(pm: PackageManager, pkg: String): Boolean {
        val component = ComponentName(pkg, HOME_ALIAS_FQCN)
        return when (pm.getComponentEnabledSetting(component)) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            // DEFAULT means "use the manifest setting", which for this
            // alias is enabled=false. Anything other than the explicit
            // ENABLED state means the alias is hidden from the system
            // home picker.
            else -> false
        }
    }

    companion object {
        private const val TAG = "LauncherPrivilege"
        private const val CHANNEL = "ilink/launcher_privilege"
        private const val HOME_ALIAS_FQCN =
            "com.i99dev.ilink.launcher.HomeActivityAlias"
    }
}

package com.i99dev.ilink.launcher

import android.app.Activity
import android.app.ActivityOptions
import android.app.role.RoleManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.Display
import com.i99dev.ilink.adb.AdbShellBridge
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Phase L2 — launcher-mode bootstrap dispatcher.
 *
 * MethodChannel `ilink/launcher_bootstrap` exposes three actions that
 * together flip ilink from "another app on the HU" to "the device's
 * home". All three are idempotent — re-running is the recovery path
 * after a partial failure.
 *
 *   * `grantAll()` — issues the launcher-tier `pm grant` / `appops set`
 *     commands over the existing loopback-ADB shell. Returns a map of
 *     `{commandKey → ok: bool, output: string}` so the Dart side can
 *     surface per-command status in the privilege grid. Safe to call
 *     when launcher mode is OFF (the grants land regardless; they only
 *     take effect when the alias is enabled).
 *   * `setLauncherModeEnabled(enabled)` — flips the `HomeActivityAlias`
 *     component-enabled state via PackageManager. Pure intra-package
 *     call; no ADB shell needed because we own the component.
 *   * `setAsDefaultHome()` — issues `cmd package set-home-activity` over
 *     loopback ADB to make us the system default home WITHOUT a picker
 *     dialog. The alias must be enabled first; this method auto-enables
 *     it as a precondition so the call sequence is single-shot.
 *
 * Read-only state (`isHomeAliasEnabled`, `isDefaultHome`, granted-perm
 * bits) lives in [LauncherPrivilegePlugin] — invalidate that provider
 * from the Dart caller after each successful action so the grid
 * refreshes.
 *
 * Threading: every action shells out, which can take several seconds
 * on a cold ADB connection. The Flutter MethodChannel runs handlers on
 * the platform thread, so we MUST offload the shell calls to a worker
 * — otherwise the UI thread blocks and Choreographer drops frames.
 * `AdbShellBridge.shell` itself is blocking; the pattern in
 * AdbBootstrapPlugin is to use a single-thread executor. We mirror
 * that pattern here.
 */
class LauncherBootstrapPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val executor = java.util.concurrent.Executors.newSingleThreadExecutor()

    init {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "grantAll" -> runOnExecutor(result) { grantAll() }
            "setLauncherModeEnabled" -> {
                // Synchronous — pure PackageManager call, no shell.
                val enabled = call.argument<Boolean>("enabled") ?: false
                try {
                    setLauncherModeEnabled(enabled)
                    result.success(null)
                } catch (t: Throwable) {
                    Log.e(TAG, "setLauncherModeEnabled failed", t)
                    result.error(
                        "LAUNCHER_TOGGLE_ERROR",
                        t.message ?: "unknown",
                        null,
                    )
                }
            }
            "requestDefaultHome" -> {
                // Synchronous — startActivity; system UI opens on its
                // own thread. No shell, no offload needed.
                try {
                    result.success(requestDefaultHome())
                } catch (t: Throwable) {
                    Log.e(TAG, "requestDefaultHome failed", t)
                    result.error(
                        "REQUEST_HOME_ERROR",
                        t.message ?: "unknown",
                        null,
                    )
                }
            }
            "enableAccessibilityServices" -> runOnExecutor(result) {
                enableAccessibilityServices()
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Run `block` on the worker thread, post the result back to the
     * platform thread (MethodChannel.Result is platform-thread only).
     * Errors thrown by `block` come back as a structured error code so
     * the Dart caller can distinguish bridge failures from per-command
     * failures (which are encoded in the success-payload map).
     */
    private fun runOnExecutor(
        result: MethodChannel.Result,
        block: () -> Map<String, Any?>,
    ) {
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        executor.execute {
            try {
                val payload = block()
                main.post { result.success(payload) }
            } catch (t: Throwable) {
                // Log the full stack here too — main-thread post only
                // carries t.message to Dart, the trace is needed for
                // BYD-vendor-quirk triage.
                Log.e(TAG, "bootstrap action threw", t)
                main.post {
                    result.error(
                        "LAUNCHER_BOOTSTRAP_ERROR",
                        t.message ?: "unknown",
                        null,
                    )
                }
            }
        }
    }

    // ── grantAll ───────────────────────────────────────────────────────

    /**
     * Idempotent grant set for launcher-mode privileges. Distinct from
     * the existing AdbBootstrap v7 set (which covers the actuator /
     * a11y / location surface) — those grants run automatically on
     * boot via AdbBootstrap.runIfNeeded; the launcher-tier ones are
     * gated behind the user opting into launcher mode in Settings.
     *
     * `pm grant` rejects PACKAGE_USAGE_STATS (it's special-access, not
     * runtime), so we use the appops form for that one — same shape
     * AdbBootstrap uses for SYSTEM_ALERT_WINDOW.
     */
    private val grantSpecs = listOf(
        GrantSpec(
            key = "readLogs",
            cmd = "pm grant $PACKAGE_ID android.permission.READ_LOGS",
        ),
        GrantSpec(
            key = "packageUsageStats",
            // appops, not pm grant — special-access perm.
            cmd = "appops set $PACKAGE_ID GET_USAGE_STATS allow",
        ),
        // NOTE: MEDIA_CONTENT_CONTROL was attempted here in the first
        // L2 cut and removed after the HU rejected it with
        // ``SecurityException: not a changeable permission type`` —
        // the perm is signature|privileged on stock Android and no
        // amount of `pm grant` flips it on a non-privileged install.
        // The music-aggregation feature will use
        // NotificationListenerService instead (user enables our
        // listener via the system Notification access panel; we then
        // call MediaSessionManager.getActiveSessions). That path
        // needs no privileged perm and is the OS-sanctioned route
        // for third-party music UIs.
    )

    private fun grantAll(): Map<String, Any?> {
        // Cold-pair window: bridge may not be reachable yet. Probe once
        // before issuing the full set so we fail fast with a clear
        // "ADB unreachable" rather than 3× per-command timeouts.
        val probe = AdbShellBridge.shell("echo ok", PROBE_TIMEOUT_MS).trim()
        if (probe.startsWith("Error:") || probe != "ok") {
            return mapOf(
                "ok" to false,
                "reason" to "adb_unreachable",
                "detail" to probe,
                "results" to emptyList<Any>(),
            )
        }
        val results = grantSpecs.map { spec ->
            val out = AdbShellBridge.shell(spec.cmd, CMD_TIMEOUT_MS).trim()
            val ok = !looksLikeError(out)
            mapOf(
                "key" to spec.key,
                "ok" to ok,
                "output" to out,
            )
        }
        val anyFailed = results.any { it["ok"] == false }
        return mapOf(
            "ok" to !anyFailed,
            "results" to results,
        )
    }

    // ── home alias toggle ──────────────────────────────────────────────

    /**
     * Flip the [HomeActivityAlias] component-enabled state. We own the
     * component so this needs no ADB and no special perms — just a
     * normal PackageManager call.
     *
     * Setting to enabled does NOT make us the default home; it just
     * makes the alias visible to the system home picker. The user
     * (or [setAsDefaultHome] below) still has to actually pick us.
     */
    private fun setLauncherModeEnabled(enabled: Boolean) {
        val pm = context.packageManager
        val component = ComponentName(context, HOME_ALIAS_FQCN)
        val newState = if (enabled) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } else {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        pm.setComponentEnabledSetting(
            component,
            newState,
            // DONT_KILL_APP — flipping the alias is harmless; killing
            // ourselves to apply the change would terminate the very UI
            // that's processing the toggle.
            PackageManager.DONT_KILL_APP,
        )
    }

    /**
     * Open the system's default-home picker so the user can pick us.
     *
     * Two strategies, tried in order:
     *
     *   1. **RoleManager.ROLE_HOME** (API 29+). The OS-sanctioned API
     *      added when the role-based default-app system replaced the
     *      legacy package-preference system. Shows a clean role-grant
     *      dialog ("Set ilink as the home app?") that the user
     *      accepts with one tap.
     *   2. **Intent(Settings.ACTION_HOME_SETTINGS)** fallback. Opens
     *      the system Home-app settings panel where the user picks
     *      from the list of registered home candidates (we're in that
     *      list because the alias is enabled). Works on every API
     *      level back to 19, and survives vendor builds where
     *      RoleManager has been stripped.
     *
     * `cmd package set-home-activity` was tried in v1 of this plugin
     * and is intentionally NOT used: BYD's vendor build rejects it
     * with ``Error: Failed to set default home`` (verified
     * 2026-05-10) — the underlying call requires
     * WRITE_PREFERRED_APPLICATIONS which is signature-only on stock
     * Android. The picker path works on every ROM at the cost of one
     * extra tap, which is the right trade.
     *
     * Auto-enables the alias first; without it the system picker
     * doesn't show us as a candidate. The status grid invalidation
     * (Dart side) covers the back-from-picker refresh.
     */
    private fun requestDefaultHome(): Map<String, Any?> {
        // Precondition: alias must be enabled or the system picker
        // won't surface us as a candidate.
        try {
            setLauncherModeEnabled(true)
        } catch (t: Throwable) {
            return mapOf(
                "ok" to false,
                "reason" to "alias_enable_failed",
                "detail" to (t.message ?: "unknown"),
            )
        }

        // Prefer launching from the foreground Activity so the system
        // UI lands on the same display the user is currently looking
        // at. Multi-display HUs (BYD has IVI + cluster + FSE +
        // passenger displays) would otherwise pick an arbitrary
        // PreferredTaskDisplayArea — verified on the L8 where the
        // home-settings panel was being routed to the FSE display
        // even though iLINK was foreground on the IVI (display 0).
        val launcher = LauncherActivityHolder.current()
        val displayId = launcher?.let(::displayIdOf) ?: Display.DEFAULT_DISPLAY
        Log.i(
            TAG,
            "requestDefaultHome: launcher=${launcher?.javaClass?.simpleName ?: "null"} " +
                "displayId=$displayId sdk=${Build.VERSION.SDK_INT}",
        )

        // Strategy 1 — `Settings.ACTION_HOME_SETTINGS`. Universal,
        // works on every API level back to 19. User opens the panel,
        // taps the Home-app row, picks iLINK from the candidate
        // list (we appear there because the alias is enabled).
        //
        // **Preferred over RoleManager.ROLE_HOME on BYD.** Verified
        // on Leopard 8 (2026-05-10): the role-grant intent launches
        // but BYD's vendor build kills the PermissionController
        // activity (`RequestRoleActivity ... hide surface ... setParent
        // new=null`) before any UI shows — BYD locks ROLE_HOME to
        // com.byd.mycar via vendor policy. The settings panel goes
        // through the unrestricted PreferredActivity API instead.
        val settingsIntent = Intent(Settings.ACTION_HOME_SETTINGS)
        try {
            startOnDisplay(launcher, settingsIntent, displayId)
            Log.i(TAG, "requestDefaultHome: home_settings intent started")
            return mapOf(
                "ok" to true,
                "method" to "home_settings",
                "displayId" to displayId,
            )
        } catch (_: Throwable) {
            // Settings activity stripped on this ROM (extremely rare;
            // vendor would have removed both the role dialog AND the
            // home-settings panel). Fall through to RoleManager.
            Log.w(TAG, "requestDefaultHome: home_settings missing, trying role_manager")
        }

        // Strategy 2 — RoleManager (API 29+). Last-resort fallback
        // for ROMs that have stripped the home-settings activity.
        // Reliably broken on BYD vendor builds; right thing on
        // stock Android / non-BYD HUs.
        if (launcher != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val rm = context.getSystemService(Context.ROLE_SERVICE)
                as? RoleManager
            if (rm != null && rm.isRoleAvailable(RoleManager.ROLE_HOME)) {
                val intent = rm.createRequestRoleIntent(RoleManager.ROLE_HOME)
                try {
                    launcher.startActivityForResult(
                        intent,
                        ROLE_HOME_REQ,
                        launchOptionsForDisplay(displayId),
                    )
                    Log.i(TAG, "requestDefaultHome: role_manager intent started")
                    return mapOf(
                        "ok" to true,
                        "method" to "role_manager",
                        "displayId" to displayId,
                    )
                } catch (t: Throwable) {
                    Log.w(TAG, "requestDefaultHome: role_manager start failed: $t")
                }
            }
        }

        Log.w(TAG, "requestDefaultHome: no picker activity available")
        return mapOf(
            "ok" to false,
            "reason" to "no_picker_activity",
            "detail" to "neither home_settings nor role_manager is reachable",
        )
    }

    /**
     * Display id the [activity] is currently rendered on. Wraps the
     * API-30+ `Activity.getDisplay()` accessor with the legacy
     * `WindowManager.getDefaultDisplay()` fallback so older builds
     * still resolve. Returns [Display.DEFAULT_DISPLAY] (0) when
     * neither path resolves — typical for test harnesses.
     */
    private fun displayIdOf(activity: Activity): Int {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                activity.display?.displayId ?: Display.DEFAULT_DISPLAY
            } else {
                @Suppress("DEPRECATION")
                activity.windowManager.defaultDisplay?.displayId
                    ?: Display.DEFAULT_DISPLAY
            }
        } catch (_: Throwable) {
            Display.DEFAULT_DISPLAY
        }
    }

    /**
     * Start [intent] from [activity] (when present) or
     * [applicationContext], pinning the launch to [displayId] via
     * `ActivityOptions.setLaunchDisplayId`. This is the standard
     * multi-display API that overrides the system's
     * PreferredTaskDisplayArea — without it, BYD's vendor policy
     * routes system activities like `HomeSettingsActivity` to the
     * FSE / passenger display instead of the user's IVI.
     */
    private fun startOnDisplay(activity: Activity?, intent: Intent, displayId: Int) {
        val opts = launchOptionsForDisplay(displayId)
        if (activity != null) {
            activity.startActivity(intent, opts)
        } else {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent, opts)
        }
    }

    /**
     * Build the `ActivityOptions` bundle that pins a launch to the
     * given display. Returns null when the launch options API isn't
     * available — the caller's `startActivity(intent, null)` is then
     * equivalent to a regular `startActivity(intent)`.
     */
    private fun launchOptionsForDisplay(displayId: Int): Bundle? {
        return try {
            ActivityOptions.makeBasic()
                .setLaunchDisplayId(displayId)
                .toBundle()
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Re-stamp the system's enabled-accessibility-services CSV so our
     * RemoteControl + Watchdog services are bound. Fixes the case
     * where AdbBootstrap.runIfNeeded short-circuited (persisted
     * version already matches target) but the OS panel has since
     * silently disabled our services — a known BYD a11y-panel
     * behaviour the watchdog itself was added to detect.
     *
     * Issues the same shell snippet [com.i99dev.ilink.adb.AdbBootstrap]
     * uses, so it stays in lockstep with the v7 grant set without
     * pulling the rest of the v7 commands (which we don't want to
     * blanket re-run from a launcher action). Idempotent — the awk
     * de-dup means re-issuing leaves the CSV unchanged when our
     * services are already in it.
     */
    private fun enableAccessibilityServices(): Map<String, Any?> {
        val probe = AdbShellBridge.shell("echo ok", PROBE_TIMEOUT_MS).trim()
        if (probe.startsWith("Error:") || probe != "ok") {
            return mapOf(
                "ok" to false,
                "reason" to "adb_unreachable",
                "detail" to probe,
            )
        }
        val results = mutableListOf<Map<String, Any?>>()
        for (cmd in A11Y_COMMANDS) {
            val out = AdbShellBridge.shell(cmd, CMD_TIMEOUT_MS).trim()
            val ok = !looksLikeError(out)
            results += mapOf("cmd" to cmd, "ok" to ok, "output" to out)
        }
        return mapOf(
            "ok" to results.all { it["ok"] == true },
            "results" to results,
        )
    }

    // ── helpers ────────────────────────────────────────────────────────

    /**
     * Same heuristic as AdbBootstrap.looksLikeError — `pm grant` /
     * `appops set` / `cmd package` print nothing on success. Failure
     * surfaces an exception trace or the literal "Error:" prefix the
     * bridge wraps connection-level errors with.
     */
    private fun looksLikeError(out: String): Boolean {
        if (out.isBlank()) return false
        val lower = out.lowercase()
        return lower.startsWith("error:") ||
            lower.contains("failure") ||
            lower.contains("exception") ||
            lower.contains("permission denial") ||
            lower.contains("not granted")
    }

    private data class GrantSpec(val key: String, val cmd: String)

    companion object {
        private const val TAG = "LauncherBootstrap"
        private const val CHANNEL = "ilink/launcher_bootstrap"
        private const val PACKAGE_ID = "com.i99dev.ilink"
        private const val HOME_ALIAS_FQCN =
            "com.i99dev.ilink.launcher.HomeActivityAlias"
        private const val CMD_TIMEOUT_MS = 5_000L
        private const val PROBE_TIMEOUT_MS = 1_500L
        // Arbitrary requestCode for startActivityForResult — the
        // result is observable via onActivityResult, but we don't
        // currently consume it (the next privilege probe carries
        // the user's actual choice).
        private const val ROLE_HOME_REQ = 0x4F4D45 // "OME"

        /**
         * Inline shell snippet that idempotently appends our two a11y
         * service ids to `secure.enabled_accessibility_services`.
         * Mirrors [com.i99dev.ilink.adb.AdbBootstrap.ENABLE_A11Y_CMD]
         * — kept in lockstep so a CSV format/component-name change
         * lands in both places. Followed by setting
         * `secure.accessibility_enabled = 1` so the framework actually
         * binds (some ROMs leave the CSV populated but the master
         * switch flipped off after a restore-defaults).
         */
        private val A11Y_COMMANDS = listOf(
            "current=\$(settings get secure enabled_accessibility_services 2>/dev/null); " +
                "want='$PACKAGE_ID/$PACKAGE_ID.input.RemoteControlAccessibilityService:" +
                "$PACKAGE_ID/$PACKAGE_ID.input.WatchdogAccessibilityService'; " +
                "merged=\$(echo \"\${current}:\${want}\" | tr ':' '\\n' | " +
                "awk 'NF && !seen[\$0]++' | paste -sd ':' -); " +
                "settings put secure enabled_accessibility_services \"\$merged\"",
            "settings put secure accessibility_enabled 1",
        )
    }
}

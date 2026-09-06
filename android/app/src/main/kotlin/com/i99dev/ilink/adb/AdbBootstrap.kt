package com.i99dev.ilink.adb

import android.content.Context
import android.content.SharedPreferences
import android.util.Log

/**
 * One-time grant set the host self-issues over loopback ADB
 * (`127.0.0.1:5555`) once the user has enabled Wireless debugging
 * during pairing. Idempotent and version-tagged: re-running the
 * commands is safe (every command is a no-op when already applied),
 * and bumping [BOOTSTRAP_VERSION] forces the next launch to re-run.
 *
 * **Phase A scope.** This bootstrap currently grants only what
 * Phase A's [SurfacePlatformPlugin] needs — the
 * `TYPE_APPLICATION_OVERLAY` fallback path when `Presentation.show()`
 * is denied on XDJA-owned cluster displays:
 *
 *   * `SYSTEM_ALERT_WINDOW` — special-access permission, declared in
 *     the manifest and flipped to "allow" via both `pm grant` and
 *     `appops set`. Some Android versions honour the `pm grant`
 *     path; others want the appops form. We run both for safety —
 *     they're idempotent and either one being a no-op is fine.
 *
 * **Originally planned for later phases**, intentionally NOT
 * granted here:
 *
 *   * `WRITE_SECURE_SETTINGS` — Phase B (accessibility services
 *     enabled via `settings put secure enabled_accessibility_services`).
 *     Re-add when those services land in the manifest.
 *   * `PACKAGE_USAGE_STATS` / `QUERY_ALL_PACKAGES` / `GET_TASKS` —
 *     Phase C (`pkg.list` / `pkg.foreground`). The latter two are
 *     install-time-only and not runtime-grantable; they need a
 *     manifest declaration only, no `pm grant`.
 *
 * **Lesson learned (first hardware run, 2026-05-01).** `pm grant`
 * requires the package to declare `<uses-permission>` first — it
 * flips a runtime bit, it doesn't create the permission. The
 * original Phase A plan said "no manifest mutations to dodge Play
 * Protect", which conflated two separate concerns: Play Store
 * sideload warnings (irrelevant — this build is sideloaded
 * directly) vs. the ADB-self-grant prerequisite. Manifest now
 * declares what the bootstrap grants.
 *
 * Thread safety: callers must invoke from a background thread (same
 * rule as `AdbShellBridge.shell` — Android forbids net I/O from
 * the UI main thread).
 */
object AdbBootstrap {
    private const val TAG = "AdbBootstrap"

    /**
     * Bump when the grant set changes. Bumping causes the next launch
     * to re-issue the full set, even on devices where the previous
     * version had run cleanly. Using an integer (not a string) keeps
     * `getInt` semantics simple — first run reads the default `0`.
     *
     * v2 (2026-05-01): trimmed to Phase A scope only, dropped
     * pm-grant lines that were rejected for missing `<uses-permission>`
     * declarations or for being install-time permissions.
     *
     * v3 (2026-05-01): Phase B — adds WRITE_SECURE_SETTINGS grant +
     * `settings put secure enabled_accessibility_services` so the
     * user doesn't have to click through BYD's a11y panel every
     * install. The two a11y services
     * (`RemoteControlAccessibilityService`, `WatchdogAccessibilityService`)
     * are auto-enabled idempotently — re-enabling is a no-op.
     *
     * v4 (2026-05-02): Phase B was merged with v3 still recorded;
     * upgrades from earlier 1.1.0-b builds skipped the new a11y
     * commands. Bumping forces those commands to run once on
     * upgrade. No new commands; `idempotent` semantics make a re-run
     * on already-bootstrapped devices a no-op.
     *
     * v5 (2026-05-02): Phase C — pkg.usage + pkg.foreground families.
     * `appops set <pkg> GET_USAGE_STATS allow` flips the runtime
     * bit for PACKAGE_USAGE_STATS without requiring the user to
     * tap through Settings → Apps with usage access. The mini-app's
     * `pkg.usage` and `pkg.foreground` reads need it; without this
     * grant, UsageStatsManager.queryUsageStats returns an empty
     * list (silent denial). QUERY_ALL_PACKAGES + GET_TASKS are
     * declared in the manifest only — install-time, no runtime
     * grant step.
     *
     * v6 (2026-05-07): Phase D — background keep-alive + continuous
     * services. Doze whitelist (`cmd deviceidle whitelist +pkg`)
     * exempts us from app-standby kills when the driver switches to
     * Maps/AAuto. `am set-standby-bucket pkg active` keeps us in
     * the ACTIVE bucket regardless of usage. The `appops` flips for
     * COARSE_LOCATION / FINE_LOCATION / RECORD_AUDIO move the
     * permission from `foreground` mode to `allow` so the foreground
     * services (VoiceSessionService, location stream) keep working
     * when the user is in another app. Two runtime perms also get
     * granted here — READ_PHONE_STATE (cellular-tech indicator) and
     * BLUETOOTH_CONNECT (audio routing to paired headset). Last
     * command grants ACCESS_BACKGROUND_LOCATION which the manifest
     * now declares; on devices still running v1.10.0-b without that
     * declaration the grant rejects, version stays at v5, and the
     * next install with the new manifest succeeds.
     *
     * v7 (2026-05-07): drop the `android.permission.PACKAGE_USAGE_STATS`
     * appops alias. The v5 comment hoped both forms would be tried
     * for ROM compatibility, but the BYD Leopard 8 stock build
     * rejects the long alias with `Unknown operation string` — which
     * trips [looksLikeError] and pins persisted_version below target
     * forever, blocking every Phase D grant from being recorded. The
     * short form `GET_USAGE_STATS` (line above the dropped one) is
     * the one this ROM actually accepts; verified in the appops dump
     * after a v6 boot. The kept command is sufficient for
     * UsageStatsManager.queryUsageStats to succeed.
     */
    // v9: + `appops set PROJECT_MEDIA allow` so the Waze arrow capture never shows
    // the system MediaProjection "Start recording or casting?" consent dialog.
    private const val BOOTSTRAP_VERSION = 9

    private const val PREFS_NAME = "ilink.adb.bootstrap"
    private const val PREF_VERSION_KEY = "applied_version"

    /** Most recent [Result] from any thread, or `null` before the
     *  first run attempt. Volatile because the onboarding plugin may
     *  query from the platform thread while the daemon-warmup thread
     *  is mid-run; assignment is once-per-run, no compound state. */
    @Volatile
    private var lastResult: Result? = null

    /** Per-command timeout in ms — `pm grant` and `settings put` are
     *  fast (<200 ms in practice). 5s gives slow-boot headroom without
     *  hanging the warmup thread for minutes if the bridge is wedged. */
    private const val CMD_TIMEOUT_MS = 5_000L

    /**
     * The package id we self-grant. Hardcoded rather than read from
     * `Context.packageName` because a misconfigured build (renamed
     * applicationId) should fail loudly here, not silently grant the
     * permissions to whatever the new package id was.
     */
    private const val PACKAGE_ID = "com.i99dev.ilink"

    /**
     * Idempotent grant commands for Phase A. Each is run via
     * `AdbShellBridge.shell` sequentially. We run BOTH the `pm grant`
     * and `appops set` paths for `SYSTEM_ALERT_WINDOW` because
     * Android API levels don't agree on which one actually flips the
     * runtime bit — running both is idempotent (the second is a
     * no-op on whichever path the OS already accepted).
     */
    private val GRANT_COMMANDS = listOf(
        // Phase A — overlay surface fallback path.
        "pm grant $PACKAGE_ID android.permission.SYSTEM_ALERT_WINDOW",
        "appops set $PACKAGE_ID SYSTEM_ALERT_WINDOW allow",
        // Phase B — secure-settings + accessibility-service auto-enable.
        // WRITE_SECURE_SETTINGS is signature|privileged in vanilla AOSP,
        // but `pm grant` from a shell session bypasses that on devices
        // that allow shell to grant it (Leopard 8 does — verified
        // 2026-05-01). On builds that reject it the next line silently
        // no-ops; the SDK then surfaces "open BYD a11y panel" as an
        // actionable error.
        "pm grant $PACKAGE_ID android.permission.WRITE_SECURE_SETTINGS",
        // Stamp the enabled-services list. Multiple services join with
        // `:`. We append (not replace) by reading current value first.
        // Idempotent: if a service id is already in the list, the
        // re-add appears once (we de-dup before writing).
        ENABLE_A11Y_CMD,
        "settings put secure accessibility_enabled 1",
        // Notification-listener access for the Nav-HUD: NavNotifListenerService
        // reads the ongoing turn-by-turn notification so the cluster keeps
        // updating when the nav app is BACKGROUNDED (the a11y scraper only sees
        // the foreground window). Without it the HUD goes blank the moment the
        // user leaves the map.
        "cmd notification allow_listener $PACKAGE_ID/$PACKAGE_ID.nav.ingest.NavNotifListenerService",
        // Phase C — usage stats grant. The canonical short form is
        // what the BYD Leopard 8 ROM accepts; an earlier comment
        // (v5) suggested also issuing the long
        // `android.permission.PACKAGE_USAGE_STATS` alias for ROM
        // compatibility, but on this hardware the long form rejects
        // with `Unknown operation string` (v7 drop). The kept
        // short-form grant is verified against the post-boot appops
        // dump and is sufficient for UsageStatsManager.queryUsageStats.
        // `pm grant` form is rejected because PACKAGE_USAGE_STATS
        // is a special-access permission, not a runtime one — appops
        // is the only path.
        "appops set $PACKAGE_ID GET_USAGE_STATS allow",
        // Phase D — background keep-alive + continuous services.
        // Doze + app-standby exemption so the OS doesn't kill us when
        // the driver switches to another app for an extended drive.
        "cmd deviceidle whitelist +$PACKAGE_ID",
        "am set-standby-bucket $PACKAGE_ID active",
        // Background-execution appops: default mode is `allow` on this
        // BYD ROM, but explicit grants survive future OS-level
        // restriction changes (Android 12+ adds OEM "background
        // restricted" toggles that flip this to `ignore`).
        "appops set $PACKAGE_ID RUN_IN_BACKGROUND allow",
        "appops set $PACKAGE_ID RUN_ANY_IN_BACKGROUND allow",
        // Move COARSE_LOCATION / FINE_LOCATION / RECORD_AUDIO from
        // `foreground` mode to `allow` so the foreground services
        // keep their continuous-stream permissions when the user
        // backgrounds the app. The FGS declarations themselves
        // (FOREGROUND_SERVICE_MICROPHONE, FOREGROUND_SERVICE_MEDIA_
        // PLAYBACK) are install-time and stay in the manifest; this
        // is just the runtime appop that gates the actual capture.
        "appops set $PACKAGE_ID COARSE_LOCATION allow",
        "appops set $PACKAGE_ID FINE_LOCATION allow",
        "appops set $PACKAGE_ID RECORD_AUDIO allow",
        // Two runtime perms denied by default until first prompt:
        // READ_PHONE_STATE backs the cellular-generation indicator;
        // BLUETOOTH_CONNECT lets the head unit route audio to a
        // paired headset. Both are declared in the manifest so
        // `pm grant` is accepted without an install-time prompt.
        "pm grant $PACKAGE_ID android.permission.READ_PHONE_STATE",
        "pm grant $PACKAGE_ID android.permission.BLUETOOTH_CONNECT",
        // Continuous-location grant. The manifest declaration was
        // added alongside this Phase D bump (1.10.x → 1.11.x). On
        // devices upgrading from 1.10.0-b without the new manifest
        // this last command rejects; bootstrap stays at v5 and
        // retries on the next OTA when the manifest catches up.
        "pm grant $PACKAGE_ID android.permission.ACCESS_BACKGROUND_LOCATION",
        // Pre-authorize MediaProjection so the Waze arrow capture never pops the
        // scary system "Start recording or casting?" consent dialog. The consent
        // activity (MediaProjectionPermissionActivity) checks the PROJECT_MEDIA
        // appop — when it's `allow` it returns RESULT_OK without showing UI. The app
        // can't grant this itself (signature-gated), but the shell bootstrap can, so
        // the Waze pixel-capture path stays invisible to the user.
        "appops set $PACKAGE_ID PROJECT_MEDIA allow",
    )

    /** The single shell snippet that idempotently appends our two a11y
     *  service ids to `secure.enabled_accessibility_services`. Inline
     *  awk is faster + safer than parse-from-Kotlin then write-back. */
    private const val ENABLE_A11Y_CMD =
        "current=\$(settings get secure enabled_accessibility_services 2>/dev/null); " +
            "want='$PACKAGE_ID/$PACKAGE_ID.input.RemoteControlAccessibilityService:" +
            "$PACKAGE_ID/$PACKAGE_ID.input.WatchdogAccessibilityService'; " +
            // De-dup: split on `:`, drop empty + any of our entries,
            // then append `want`. Final value is the union with
            // duplicates removed — preserves user's other a11y
            // services (TalkBack etc.).
            "merged=\$(echo \"\${current}:\${want}\" | tr ':' '\\n' | " +
            "awk 'NF && !seen[\$0]++' | paste -sd ':' -); " +
            "settings put secure enabled_accessibility_services \"\$merged\""

    /**
     * Run the bootstrap if the persisted version is below
     * [BOOTSTRAP_VERSION]. Returns:
     *   * [Result.AlreadyApplied] — no-op fast path.
     *   * [Result.Applied] — every command ran without an obvious
     *     error string in stdout/stderr.
     *   * [Result.Skipped] — bridge not reachable; will retry on next
     *     boot. Not an error per se: cold-pair window before the user
     *     enables Wireless debugging hits this.
     *   * [Result.Failed] — at least one command came back with an
     *     error string. Persisted version is NOT advanced; next boot
     *     will retry.
     */
    fun runIfNeeded(context: Context): Result {
        val prefs = context.applicationContext.getSharedPreferences(
            PREFS_NAME, Context.MODE_PRIVATE,
        )
        val applied = prefs.getInt(PREF_VERSION_KEY, 0)
        if (applied >= BOOTSTRAP_VERSION) {
            Log.i(TAG, "bootstrap v$BOOTSTRAP_VERSION already applied (record=v$applied) — skip")
            return Result.AlreadyApplied(applied).also { lastResult = it }
        }

        if (!AdbShellBridge.isConnected()) {
            // ensureDaemon does its own connect attempt; we use shell()
            // below which also reconnects, but a quick precheck avoids
            // running the whole list against a guaranteed failure.
            val probe = AdbShellBridge.shell("echo ok", 1_500)
            if (probe.startsWith("Error:")) {
                Log.w(TAG, "ADB not reachable — will retry next boot ($probe)")
                return Result.Skipped(probe).also { lastResult = it }
            }
        }

        val failures = mutableListOf<String>()
        for (cmd in GRANT_COMMANDS) {
            val out = AdbShellBridge.shell(cmd, CMD_TIMEOUT_MS).trim()
            if (looksLikeError(out)) {
                failures += "$cmd → $out"
                Log.w(TAG, "bootstrap step failed: $cmd → $out")
            } else {
                Log.i(TAG, "bootstrap step ok: $cmd")
            }
        }

        if (failures.isNotEmpty()) {
            Log.e(TAG, "bootstrap v$BOOTSTRAP_VERSION partial (${failures.size}/${GRANT_COMMANDS.size} failed); will retry next boot")
            return Result.Failed(failures).also { lastResult = it }
        }

        prefs.edit().putInt(PREF_VERSION_KEY, BOOTSTRAP_VERSION).apply()
        Log.i(TAG, "bootstrap v$BOOTSTRAP_VERSION applied (${GRANT_COMMANDS.size} commands)")
        return Result.Applied(BOOTSTRAP_VERSION, GRANT_COMMANDS.size).also { lastResult = it }
    }

    /**
     * Onboarding hook: snapshot of the persisted vs target version
     * plus the most recent [Result]. Cheap — no work, no I/O beyond
     * a SharedPreferences read. Safe to call from the platform thread.
     *
     * Returns a stable Map for the method-channel boundary so the
     * Dart side doesn't need to know the [Result] subclasses.
     */
    fun getStatusMap(context: Context): Map<String, Any?> {
        val applied = context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getInt(PREF_VERSION_KEY, 0)
        val last = lastResult
        val (kind, detail, failureCount) = when (last) {
            null -> Triple("unknown", null, 0)
            is Result.AlreadyApplied -> Triple("alreadyApplied", null, 0)
            is Result.Applied -> Triple("applied", null, 0)
            is Result.Skipped -> Triple("skipped", last.reason, 0)
            is Result.Failed -> Triple("failed", last.failures.firstOrNull(), last.failures.size)
        }
        return mapOf(
            "persistedVersion" to applied,
            "targetVersion" to BOOTSTRAP_VERSION,
            "lastResultKind" to kind,
            "lastResultDetail" to detail,
            "lastFailureCount" to failureCount,
        )
    }

    /**
     * Onboarding hook: drop the persisted version and re-run the full
     * grant set. Used when the cold-launch attempt returned [Result.Skipped]
     * (Wireless debugging not yet enabled) and the user has now
     * enabled it via the Settings UI. Runs synchronously on the
     * caller's thread — caller is responsible for offloading from the
     * UI thread (the channel handler in [AdbBootstrapPlugin] does so).
     */
    fun retry(context: Context): Result {
        resetPersistedVersion(context)
        return runIfNeeded(context)
    }

    /**
     * Test/diagnostic hook: drop the persisted version so the next
     * `runIfNeeded` re-issues every grant. Used by the OTA path when
     * the host detects a permission has been revoked on-device (e.g.
     * a system update flipped them).
     */
    fun resetPersistedVersion(context: Context) {
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(PREF_VERSION_KEY)
            .apply()
    }

    /**
     * Heuristic: `pm grant` and `settings put` print nothing on
     * success. Failure surfaces an exception trace ("Failure", "Error",
     * "Exception", "Permission denial", "java.lang…"). The bridge wraps
     * its own connection-level errors with the literal "Error:" prefix.
     */
    private fun looksLikeError(out: String): Boolean {
        if (out.isBlank()) return false
        val lower = out.lowercase()
        return lower.startsWith("error:") ||
            lower.contains("failure") ||
            lower.contains("exception") ||
            lower.contains("permission denial")
    }

    sealed class Result {
        data class AlreadyApplied(val version: Int) : Result()
        data class Applied(val version: Int, val commandCount: Int) : Result()
        data class Skipped(val reason: String) : Result()
        data class Failed(val failures: List<String>) : Result()
    }
}

package com.i99dev.ilink.pkg

import android.util.Log
import com.i99dev.ilink.adb.AdbShellBridge

/**
 * Single-owner classifier + retry helper for every `am ...` shell
 * command issued via the loopback-ADB bridge.
 *
 * Background — BYD WMS bug. The Leopard 8 ROM has a known
 * `ClassCastException: ActivityRecord cannot be cast to Task` at
 * `Task.java:5442` that fires whenever a Task contains a single
 * ActivityRecord child. Symptoms surface as intermittent failures of
 * `am start-activity --display N`, `am stack move-task`, and
 * `am force-stop` — the first attempt commonly fails, the second
 * (issued ~250 ms later) usually succeeds because the WMS state has
 * settled.
 *
 * Why centralize. Pre-2026-05-07 each launch site duplicated the
 * `out.contains("Error", ignoreCase = true)` parsing AND none of
 * them retried. That meant six places to touch when classification
 * needed sharpening, six different breadcrumb shapes for telemetry,
 * and zero retry on a transient ROM bug. This object replaces the
 * ad-hoc parsing — every shell-based launch should route through
 * [runWithRetry].
 *
 * Usage from a launch site:
 * ```
 * when (val r = AmShellRunner.runWithRetry(cmd, timeoutMs = 4_000L)) {
 *   is AmShellResult.Ok -> ...
 *   is AmShellResult.WmsTransient -> ...   // user-actionable retry
 *   is AmShellResult.HardFailure -> ...    // not-recoverable
 * }
 * ```
 *
 * Threading: callers must already be on a worker thread (the
 * AdbShellBridge does net I/O; calling from the main thread crashes
 * with NetworkOnMainThreadException). Existing call sites in
 * `PackagePlatformPlugin` route through `adbExecutor` — keep that.
 */
object AmShellRunner {
    private const val TAG = "AmShellRunner"

    /** Functional shape of the loopback-ADB shell call. Production uses
     *  `AdbShellBridge::shell`; tests inject a recording stub. Kept
     *  as a typealias-style functional type rather than an interface so
     *  callers can pass any 2-arg `(String, Long) -> String` without
     *  ceremony — the only place this type appears in the public API
     *  is the default value of `shell` on [runWithRetry] / [runOnce]. */
    private val DEFAULT_SHELL: (String, Long) -> String = AdbShellBridge::shell

    /** Default initial backoff between attempts (ms). The BYD WMS state
     *  typically settles within ~200 ms of a transient hit; 250 ms gives
     *  comfortable margin without delaying the success case. */
    const val DEFAULT_BACKOFF_MS = 250L

    /** Default retry budget. Routine launches use 1 (= two total
     *  attempts). High-value paths like cluster `surface.create` override
     *  to [SURFACE_CREATE_MAX_RETRIES] with [EXPONENTIAL_BACKOFF]. */
    const val DEFAULT_MAX_RETRIES = 1

    /** Retry budget for the cluster `surface.create` path. Empirically
     *  the BYD WMS sometimes needs 3-4 attempts to settle when the
     *  cluster service is racing with amap on Leopard 8; bumping from
     *  1 → 3 (i.e. four total attempts with progressive backoff)
     *  converts the visible `surface_wms_transient` banner into a
     *  hidden internal retry on the vast majority of pushes. */
    const val SURFACE_CREATE_MAX_RETRIES = 3

    /** Hard cap on the exponential-backoff exponent — caps growth at
     *  16× the initial delay so a high [maxRetries] can't accidentally
     *  configure a pathological multi-minute wait. */
    private const val EXPONENT_CAP = 4

    /** Constant-delay schedule — every retry waits [DEFAULT_BACKOFF_MS].
     *  Historical default; cheap, no allocations on the success path. */
    val CONSTANT_BACKOFF: (Int) -> Long = { _ -> DEFAULT_BACKOFF_MS }

    /** Progressive (exponential) schedule starting at [DEFAULT_BACKOFF_MS]
     *  and doubling each retry, e.g. 250 → 500 → 1000 → 2000 ms. The
     *  common-case singleton: zero allocation on the fast path. Use
     *  [exponentialBackoff] for a non-default initial delay. */
    val EXPONENTIAL_BACKOFF: (Int) -> Long = exponentialBackoff(DEFAULT_BACKOFF_MS)

    /** Factory for an exponential schedule starting at [initialMs].
     *  Returns a lambda that doubles the wait each retry, capped at
     *  [EXPONENT_CAP] (~16× initial). Use for paths that want progressive
     *  backoff but with a non-default initial — e.g. a slow boot path
     *  that wants 500 → 1000 → 2000 ms. For the common 250 ms case
     *  prefer the [EXPONENTIAL_BACKOFF] singleton (no closure capture). */
    fun exponentialBackoff(initialMs: Long): (Int) -> Long = { attempt ->
        val safe = attempt.coerceIn(0, EXPONENT_CAP)
        initialMs shl safe
    }

    /**
     * Issue [cmd] over the loopback-ADB bridge with a [timeoutMs]
     * per attempt, retrying up to [maxRetries] times on a transient
     * WMS-shape failure. The [backoff] schedule is consulted between
     * attempts — `backoff(0)` runs before the first retry, `backoff(1)`
     * before the second, etc. Returns the classified result of the
     * last attempt. The Sentry-noise contract is "first-attempt
     * failures are not breadcrumbed" — the caller decides whether to
     * surface a final-attempt failure (typically yes for HardFailure,
     * yes for WmsTransient that exhausted retries).
     */
    fun runWithRetry(
        cmd: String,
        timeoutMs: Long,
        maxRetries: Int = DEFAULT_MAX_RETRIES,
        backoff: (Int) -> Long = CONSTANT_BACKOFF,
        shell: (String, Long) -> String = DEFAULT_SHELL,
        sleeper: (Long) -> Unit = Thread::sleep,
    ): AmShellResult {
        var attempt = 0
        var lastResult: AmShellResult = AmShellResult.HardFailure(
            out = "",
            reason = "no attempt issued",
            attempts = 0,
        )
        while (attempt <= maxRetries) {
            val attemptsSoFar = attempt + 1
            val out = try {
                shell(cmd, timeoutMs)
            } catch (t: Throwable) {
                "Error: ${t.message ?: t.javaClass.simpleName}"
            }
            lastResult = classify(out).withAttempts(attemptsSoFar)
            when (lastResult) {
                is AmShellResult.Ok -> return lastResult
                is AmShellResult.WmsTransient -> {
                    if (attempt < maxRetries) {
                        val delayMs = backoff(attempt)
                        Log.i(
                            TAG,
                            "wms_transient retry attempt=${attemptsSoFar}/${maxRetries + 1} " +
                                "delay=${delayMs}ms: ${lastResult.out.take(120)}",
                        )
                        sleeper(delayMs)
                        attempt++
                        continue
                    }
                    Log.w(TAG, "wms_transient exhausted retries: ${lastResult.out.take(200)}")
                    return lastResult
                }
                is AmShellResult.HardFailure -> {
                    // Not retryable — permission denial, bad component, etc.
                    Log.w(
                        TAG,
                        "hard_failure (no retry): ${lastResult.reason} :: ${lastResult.out.take(200)}",
                    )
                    return lastResult
                }
            }
        }
        return lastResult
    }

    /** Returns a copy of this result with [attempts] set. Used internally
     *  by [runWithRetry] so [classify] (the single-attempt path) doesn't
     *  need to know the call's retry context. */
    private fun AmShellResult.withAttempts(n: Int): AmShellResult = when (this) {
        is AmShellResult.Ok -> copy(attempts = n)
        is AmShellResult.WmsTransient -> copy(attempts = n)
        is AmShellResult.HardFailure -> copy(attempts = n)
    }

    /**
     * Issue [cmd] once with [timeoutMs] and return the classified
     * result. Use this for non-launch shell commands (e.g.
     * `am stack list` for verification reads) where retry on
     * a transient failure is not meaningful — the caller already
     * loops or polls.
     */
    fun runOnce(
        cmd: String,
        timeoutMs: Long,
        shell: (String, Long) -> String = DEFAULT_SHELL,
    ): AmShellResult {
        val out = try {
            shell(cmd, timeoutMs)
        } catch (t: Throwable) {
            "Error: ${t.message ?: t.javaClass.simpleName}"
        }
        return classify(out)
    }

    /**
     * Classify a shell `out` body into one of three buckets. Public
     * so call sites that already have a captured `out` (e.g. a verify
     * step that issued the shell themselves) can reuse the same
     * classifier without re-running the command.
     *
     * Heuristics:
     *   * Empty / whitespace → HardFailure (the bridge wraps its own
     *     errors with "Error:"; an empty body usually means the
     *     bridge itself dropped the connection).
     *   * Contains BYD-WMS shape (`ClassCastException`,
     *     `is not task`, `Activity not started`,
     *     `WindowManager.InvalidDisplayException`) → WmsTransient.
     *   * Contains hard-failure shape (`Permission Denial`,
     *     `Unknown command`, `not installed for the current user`)
     *     → HardFailure.
     *   * Other "Error:"/"Exception"/"Failure" lines → HardFailure
     *     by default; safer to surface than to retry-spin.
     *   * Anything else → Ok.
     */
    fun classify(out: String): AmShellResult {
        val trimmed = out.trim()
        if (trimmed.isEmpty()) {
            return AmShellResult.HardFailure(out = trimmed, reason = "empty_output")
        }
        val lower = trimmed.lowercase()

        // BYD-specific transient shape. These are the strings observed
        // in real-device logcat on Leopard 8 (Q0414) when the WMS
        // ClassCastException fires during an activity launch.
        val isWmsTransient = lower.contains("classcastexception") ||
            lower.contains("is not task") ||
            lower.contains("activity not started") ||
            lower.contains("invaliddisplayexception") ||
            lower.contains("displaycontentcurrent")
        if (isWmsTransient) {
            return AmShellResult.WmsTransient(out = trimmed)
        }

        // Hard failures — don't retry these; they need user / config fix.
        val hardReason = when {
            lower.contains("permission denial") -> "permission_denial"
            lower.contains("unknown command") -> "unknown_command"
            lower.contains("not installed for the current user") -> "package_not_installed"
            lower.contains("does not exist") -> "component_not_found"
            lower.contains("securityexception") -> "security_exception"
            // `am stack move-task` into a non-`standard`/cross-user
            // root task (the Leopard 8 FSE multi-user home stack):
            // ATMS rejects it deterministically with
            // `IllegalArgumentException: moveTaskToRootTask`. NOT a
            // transient — never retry — but distinct from a generic
            // uncaught exception so `doMove` can deterministically
            // trigger its `am start --display` fallback, and so the
            // user-facing error reads `move_task_rejected` instead of
            // the opaque `uncaught_exception`.
            lower.contains("movetasktoroottask") -> "move_task_rejected"
            lower.startsWith("error:") -> "shell_error"
            lower.contains("exception") -> "uncaught_exception"
            lower.contains("failure") -> "shell_failure"
            else -> null
        }
        if (hardReason != null) {
            return AmShellResult.HardFailure(out = trimmed, reason = hardReason)
        }

        return AmShellResult.Ok(out = trimmed)
    }
}

/**
 * Tagged result of an `am ...` shell run. The [out] body is preserved
 * across all branches so call sites can include it in
 * user-facing error strings or telemetry. [attempts] counts how many
 * shell invocations actually issued (1 = first-try success / first-try
 * hard failure; >1 = retry recovered the call; `maxRetries + 1` =
 * retries exhausted). Call sites use it to emit a histogram-shaped
 * Sentry counter — see SurfacePlatformPlugin / PackagePlatformPlugin.
 */
sealed class AmShellResult {
    abstract val out: String
    abstract val attempts: Int

    /** Shell command completed cleanly. */
    data class Ok(override val out: String, override val attempts: Int = 1) : AmShellResult()

    /**
     * BYD WMS transient — the shell call hit the known
     * `Task.java:5442` ClassCastException family. Caller can surface
     * a "Retry" affordance to the user; [AmShellRunner] already
     * exhausted the call site's retry budget (default
     * [DEFAULT_MAX_RETRIES], [SURFACE_CREATE_MAX_RETRIES] for cluster
     * surface creation) before returning this, so additional
     * same-process retries are unlikely to help.
     */
    data class WmsTransient(
        override val out: String,
        override val attempts: Int = 1,
    ) : AmShellResult()

    /**
     * Not retryable — permission denial, missing component, malformed
     * intent, etc. Caller surfaces a typed error to the user with
     * [reason] so the UI / Sentry can branch on category.
     */
    data class HardFailure(
        override val out: String,
        val reason: String,
        override val attempts: Int = 1,
    ) : AmShellResult()
}

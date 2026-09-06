package com.i99dev.ilink.pkg

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * Unit tests for [AmShellRunner].
 *
 * Scope: pure-Kotlin classification + retry budget + backoff curve.
 * No Android framework, no real ADB — the shell call is stubbed via
 * the `shell` and `sleeper` parameters so tests run on a plain JVM
 * (`./gradlew :app:testDebugUnitTest`).
 *
 * What this file LOCKS IN:
 *   * The ROM-error-string heuristics in `classify()` — first line
 *     of defense against a Leopard 8 ROM bump that ships a slightly
 *     different exception shape.
 *   * The exponential-backoff curve cap — guards against a future
 *     contributor accidentally configuring a multi-minute delay.
 *   * Retry budget accounting — the `attempts` field that the
 *     Sentry dashboards bucket on must stay accurate.
 *   * The `surface.create` profile (3 retries, exponential) — a
 *     regression here is exactly the bug we just shipped a fix for.
 */
class AmShellRunnerTest {

    // ── classify() heuristics ──────────────────────────────────────────────

    @Test fun `classify empty output is HardFailure with empty_output reason`() {
        val r = AmShellRunner.classify("")
        assertIs<AmShellResult.HardFailure>(r)
        assertEquals("empty_output", r.reason)
    }

    @Test fun `classify whitespace-only output is HardFailure`() {
        assertIs<AmShellResult.HardFailure>(AmShellRunner.classify("   \n  "))
    }

    @Test fun `classify clean output is Ok`() {
        val r = AmShellRunner.classify("Starting: Intent { act=...")
        assertIs<AmShellResult.Ok>(r)
    }

    @Test fun `classify ClassCastException is WmsTransient (BYD ROM bug)`() {
        val out = "java.lang.ClassCastException: ActivityRecord cannot be cast to Task\n" +
            "    at com.android.server.wm.Task.java:5442"
        assertIs<AmShellResult.WmsTransient>(AmShellRunner.classify(out))
    }

    @Test fun `classify 'is not task' is WmsTransient`() {
        assertIs<AmShellResult.WmsTransient>(
            AmShellRunner.classify("Error: rootTask is not Task"),
        )
    }

    @Test fun `classify 'Activity not started' is WmsTransient`() {
        assertIs<AmShellResult.WmsTransient>(
            AmShellRunner.classify("Activity not started, its current task has been brought to the front"),
        )
    }

    @Test fun `classify 'InvalidDisplayException' is WmsTransient`() {
        assertIs<AmShellResult.WmsTransient>(
            AmShellRunner.classify("android.view.WindowManager.InvalidDisplayException: blah"),
        )
    }

    @Test fun `classify 'Permission Denial' is HardFailure with reason`() {
        val r = AmShellRunner.classify("Permission Denial: starting Intent")
        assertIs<AmShellResult.HardFailure>(r)
        assertEquals("permission_denial", r.reason)
    }

    @Test fun `classify 'Unknown command' is HardFailure`() {
        val r = AmShellRunner.classify("Unknown command: foo")
        assertIs<AmShellResult.HardFailure>(r)
        assertEquals("unknown_command", r.reason)
    }

    @Test fun `classify 'not installed for the current user' is HardFailure`() {
        val r = AmShellRunner.classify("Package x.y.z is not installed for the current user")
        assertIs<AmShellResult.HardFailure>(r)
        assertEquals("package_not_installed", r.reason)
    }

    @Test fun `classify 'does not exist' is HardFailure with component_not_found`() {
        val r = AmShellRunner.classify("Error: Activity class {x/y} does not exist")
        assertIs<AmShellResult.HardFailure>(r)
        assertEquals("component_not_found", r.reason)
    }

    @Test fun `classify 'SecurityException' is HardFailure`() {
        val r = AmShellRunner.classify("java.lang.SecurityException: not allowed")
        assertIs<AmShellResult.HardFailure>(r)
        assertEquals("security_exception", r.reason)
    }

    @Test fun `classify moveTaskToRootTask reject is HardFailure move_task_rejected`() {
        // Verbatim from the L8 test car (192.168.4.72) when migrating
        // an app INTO the FSE multi-user home stack (RootTask 81):
        //   am stack move-task 119 81 true
        // ATMS rejects it deterministically — NOT a transient, must
        // not retry, and must be distinct from `uncaught_exception`
        // so doMove can trigger its am-start fallback. Note the body
        // also contains "exception"; the move-task branch must win.
        val out = "Exception occurred while executing 'stack':\n" +
            "java.lang.IllegalArgumentException: moveTaskToRootTask: " +
            "Attempt to move task 119 to rootTask 81\n" +
            "\tat com.android.server.wm.ActivityTaskManagerService" +
            ".moveTaskToRootTask(ActivityTaskManagerService.java:2623)"
        val r = AmShellRunner.classify(out)
        assertIs<AmShellResult.HardFailure>(r)
        assertEquals("move_task_rejected", r.reason)
    }

    @Test fun `classify benign ClassCast move-task stays WmsTransient (not rejected)`() {
        // The OTHER FSE-adjacent shape: move-task to a *standard*
        // stack on Leopard 8 prints the benign Task.java:5442
        // ClassCastException but the move SUCCEEDS. Must remain
        // WmsTransient (retry + read-back verify), never confused
        // with the structural move_task_rejected reject above.
        val out = "Exception occurred while executing 'stack':\n" +
            "java.lang.ClassCastException: " +
            "com.android.server.wm.ActivityRecord cannot be cast to " +
            "com.android.server.wm.Task\n" +
            "\tat com.android.server.wm.Task" +
            ".resumeTopActivityUncheckedLocked(Task.java:5442)"
        assertIs<AmShellResult.WmsTransient>(AmShellRunner.classify(out))
    }

    @Test fun `classify 'Error -' prefix is HardFailure shell_error`() {
        val r = AmShellRunner.classify("Error: bridge dropped")
        assertIs<AmShellResult.HardFailure>(r)
        assertEquals("shell_error", r.reason)
    }

    // ── backoff schedules ──────────────────────────────────────────────────

    @Test fun `CONSTANT_BACKOFF returns 250ms regardless of attempt`() {
        assertEquals(250L, AmShellRunner.CONSTANT_BACKOFF(0))
        assertEquals(250L, AmShellRunner.CONSTANT_BACKOFF(1))
        assertEquals(250L, AmShellRunner.CONSTANT_BACKOFF(99))
    }

    @Test fun `EXPONENTIAL_BACKOFF doubles each attempt`() {
        assertEquals(250L, AmShellRunner.EXPONENTIAL_BACKOFF(0))
        assertEquals(500L, AmShellRunner.EXPONENTIAL_BACKOFF(1))
        assertEquals(1000L, AmShellRunner.EXPONENTIAL_BACKOFF(2))
        assertEquals(2000L, AmShellRunner.EXPONENTIAL_BACKOFF(3))
    }

    @Test fun `EXPONENTIAL_BACKOFF caps at 4 (16x) for pathological inputs`() {
        // 250 << 4 = 4000ms — the cap. Anything beyond stays at 4000.
        assertEquals(4000L, AmShellRunner.EXPONENTIAL_BACKOFF(4))
        assertEquals(4000L, AmShellRunner.EXPONENTIAL_BACKOFF(10))
        assertEquals(4000L, AmShellRunner.EXPONENTIAL_BACKOFF(Int.MAX_VALUE))
    }

    @Test fun `exponentialBackoff factory honours non-default initial`() {
        val b = AmShellRunner.exponentialBackoff(500L)
        assertEquals(500L, b(0))
        assertEquals(1000L, b(1))
        assertEquals(2000L, b(2))
        // Same 16x cap applies.
        assertEquals(8000L, b(4))
        assertEquals(8000L, b(99))
    }

    // ── runWithRetry: attempts, retry budget, ordering ─────────────────────

    @Test fun `runWithRetry returns first-try Ok with attempts=1`() {
        val r = AmShellRunner.runWithRetry(
            cmd = "any",
            timeoutMs = 1_000L,
            shell = { _, _ -> "ok" },
            sleeper = {},
        )
        assertIs<AmShellResult.Ok>(r)
        assertEquals(1, r.attempts)
    }

    @Test fun `runWithRetry retries on WmsTransient and reports recovery attempts`() {
        var calls = 0
        val r = AmShellRunner.runWithRetry(
            cmd = "any",
            timeoutMs = 1_000L,
            maxRetries = 3,
            shell = { _, _ ->
                calls++
                if (calls < 3) "java.lang.ClassCastException: bad" else "ok"
            },
            sleeper = {},
        )
        assertIs<AmShellResult.Ok>(r)
        assertEquals(3, r.attempts)
        assertEquals(3, calls)
    }

    @Test fun `runWithRetry exhausts budget on persistent WmsTransient`() {
        var calls = 0
        val r = AmShellRunner.runWithRetry(
            cmd = "any",
            timeoutMs = 1_000L,
            maxRetries = 3,
            shell = { _, _ ->
                calls++
                "java.lang.ClassCastException: bad"
            },
            sleeper = {},
        )
        assertIs<AmShellResult.WmsTransient>(r)
        // maxRetries=3 means 4 total attempts (initial + 3 retries).
        assertEquals(4, r.attempts)
        assertEquals(4, calls)
    }

    @Test fun `runWithRetry does NOT retry on HardFailure`() {
        var calls = 0
        val r = AmShellRunner.runWithRetry(
            cmd = "any",
            timeoutMs = 1_000L,
            maxRetries = 3,
            shell = { _, _ ->
                calls++
                "Permission Denial: nope"
            },
            sleeper = {},
        )
        assertIs<AmShellResult.HardFailure>(r)
        assertEquals(1, r.attempts)
        assertEquals(1, calls)
    }

    @Test fun `runWithRetry consults backoff schedule with correct attempt indices`() {
        val backoffCalls = mutableListOf<Int>()
        val sleepDelays = mutableListOf<Long>()
        AmShellRunner.runWithRetry(
            cmd = "any",
            timeoutMs = 1_000L,
            maxRetries = 3,
            backoff = { attempt ->
                backoffCalls += attempt
                (attempt + 1) * 100L
            },
            shell = { _, _ -> "java.lang.ClassCastException" },
            sleeper = { sleepDelays += it },
        )
        // backoff(0) before first retry, backoff(1) before second, backoff(2) before third.
        // No backoff after the final attempt (no further retry would follow).
        assertEquals(listOf(0, 1, 2), backoffCalls)
        assertEquals(listOf(100L, 200L, 300L), sleepDelays)
    }

    @Test fun `runWithRetry treats shell exception as a transient-classifiable Error`() {
        val r = AmShellRunner.runWithRetry(
            cmd = "any",
            timeoutMs = 1_000L,
            shell = { _, _ -> throw RuntimeException("bridge dropped") },
            sleeper = {},
        )
        // "Error: bridge dropped" is classified as shell_error (HardFailure).
        assertIs<AmShellResult.HardFailure>(r)
        assertEquals("shell_error", r.reason)
    }

    // ── surface.create profile: the regression we just fixed ──────────────

    @Test fun `surface-create profile = 4 total attempts with exponential backoff`() {
        var calls = 0
        val sleepDelays = mutableListOf<Long>()
        val r = AmShellRunner.runWithRetry(
            cmd = "am start-activity --display 4 com.foo",
            timeoutMs = 8_000L,
            maxRetries = AmShellRunner.SURFACE_CREATE_MAX_RETRIES,
            backoff = AmShellRunner.EXPONENTIAL_BACKOFF,
            shell = { _, _ ->
                calls++
                "java.lang.ClassCastException: ActivityRecord cannot be cast to Task"
            },
            sleeper = { sleepDelays += it },
        )
        assertIs<AmShellResult.WmsTransient>(r)
        assertEquals(4, calls) // initial + 3 retries
        assertEquals(4, r.attempts)
        // Curve: 250, 500, 1000 between the 4 attempts.
        assertEquals(listOf(250L, 500L, 1000L), sleepDelays)
    }

    @Test fun `runOnce passes through to shell without retry`() {
        var calls = 0
        val r = AmShellRunner.runOnce(
            cmd = "any",
            timeoutMs = 1_000L,
            shell = { _, _ ->
                calls++
                "java.lang.ClassCastException"
            },
        )
        assertIs<AmShellResult.WmsTransient>(r)
        assertEquals(1, calls)
        // runOnce doesn't set attempts itself; defaults to 1.
        assertEquals(1, r.attempts)
    }

    @Test fun `default constants reflect documented contract`() {
        // These constants are referenced by SurfacePlatformPlugin and
        // any future call site; a change to either is a wire-level
        // policy bump and must be intentional.
        assertEquals(250L, AmShellRunner.DEFAULT_BACKOFF_MS)
        assertEquals(1, AmShellRunner.DEFAULT_MAX_RETRIES)
        assertEquals(3, AmShellRunner.SURFACE_CREATE_MAX_RETRIES)
    }

    @Test fun `WmsTransient out body is preserved through the retry path`() {
        val firstOut = "first call: java.lang.ClassCastException line 1"
        val finalOut = "last call: java.lang.ClassCastException line 9"
        var n = 0
        val r = AmShellRunner.runWithRetry(
            cmd = "any",
            timeoutMs = 1_000L,
            maxRetries = 1,
            shell = { _, _ -> if (n++ == 0) firstOut else finalOut },
            sleeper = {},
        )
        assertIs<AmShellResult.WmsTransient>(r)
        // Only the final attempt's output is returned (the caller logs
        // first-attempt failures via runner's own Log.i).
        assertTrue(r.out.contains("last call"))
    }
}

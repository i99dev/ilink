package com.i99dev.ilink.pkg

/**
 * Single-source-of-truth parser for `am stack list` output.
 *
 * Lifted verbatim from the inline helpers that used to live in
 * [PackagePlatformPlugin] (`findTaskForPackage`, `findRootTaskOnDisplay`,
 * `displayOfTask`). Two consumers share the parse output:
 *
 *   1. **Launch decision path** — [LaunchStrategyResolver] reads the
 *      task topology to choose Resume / Migrate / FreshLaunch. Without
 *      this lookup, every non-default-display launch unconditionally
 *      passes `--activity-multiple-task` and spawns a fresh task even
 *      when one already exists for the package — the cause of the
 *      "double-launches the same app" bug A.
 *   2. **`pkg.running` MethodChannel op** — the Dart-side
 *      `runningAppsControllerProvider` polls this every ~2 s while the
 *      home screen is mounted to feed the per-display chip strip.
 *
 * Output shape (unchanged from BYD ROMs we ship on):
 *
 *     RootTask id=N bounds=[…] displayId=D userId=0
 *      configuration={…}
 *       taskId=T: pkg/.SomeActivity bounds=[…] visible=true|false
 *
 * The `visible=true` token is what the foreground heuristic keys on —
 * it's the closest cheap signal we have without a dumpsys window
 * pass. Multiple tasks can carry `visible=true` simultaneously
 * (per-display foreground), which is exactly the semantic we want for
 * a multi-display "what's on screen X" view.
 *
 * **No Android imports** — this parser is a pure function over a
 * String. The next person wiring up a JVM unit-test source set should
 * have a clean target here.
 */
data class TaskRow(
    val taskId: Int,
    val rootTaskId: Int,
    val displayId: Int,
    val packageName: String,
    val isForeground: Boolean,
)

/** Header line in `am stack list`. Emitted even for empty stacks so
 *  the Migrate path can detect that a display already has a root
 *  stack to move INTO without spawning a placeholder ClusterActivity. */
data class RootTaskRow(
    val rootTaskId: Int,
    val displayId: Int,
    /**
     * `mActivityType` off the `configuration={…}` line that follows
     * the header (`"standard"`, `"home"`, `"undefined"`, …). Empty
     * when the ROM emitted no configuration line.
     *
     * This is the decisive `am stack move-task` *target* signal: ATMS
     * rejects reparenting a `standard` task into a non-`standard`
     * (e.g. `home`) root task with
     * `IllegalArgumentException: moveTaskToRootTask`. On Leopard 8 the
     * FSE display's only persistent stack is the multi-user launcher
     * **home** (`com.android.launcher3.fse`, `mActivityType=home`),
     * so targeting it is the FSE-relocation hard-fail. See
     * [findRootTaskOnDisplay].
     */
    val activityType: String = "",
    /**
     * `userId` off the header. The FSE home stack's header reports
     * `0` even though its child task is `u999`, so [activityType] —
     * not this — is the load-bearing movability check; `userId` is
     * kept for the cross-user defense + observability.
     */
    val userId: Int = 0,
)

/** Bundled parse result so the launch path can hand a single
 *  snapshot to [LaunchStrategyResolver] without re-parsing. */
data class StackSnapshot(
    val tasks: List<TaskRow>,
    val rootTasks: List<RootTaskRow>,
)

object AmStackParser {

    private val ROOT_RX =
        Regex("""RootTask id=(\d+)\s+bounds=\S+\s+displayId=(\d+)(?:\s+userId=(\d+))?""")
    private val TASK_RX =
        Regex("""\s*taskId=(\d+):\s+(\S+)/(?:\S*)?\s*(.*)""")

    /** `mActivityType=` token off the `configuration={…}` line that
     *  immediately follows a RootTask header on every BYD ROM we
     *  ship on. */
    private val ACTIVITY_TYPE_RX = Regex("""mActivityType=(\S+)""")

    /**
     * Full parse — returns both task rows and root-task headers. Hot
     * path: called once per launch (cache miss) and once per polling
     * tick from the running-apps controller.
     */
    fun parse(amStackList: String): StackSnapshot {
        var currentRootTaskId: Int? = null
        var currentDisplay: Int? = null
        val tasks = mutableListOf<TaskRow>()
        val roots = mutableListOf<RootTaskRow>()
        // A RootTask header is parsed before its `activityType` is
        // known (that's on the *next* `configuration={…}` line). We
        // hold the header here and emit it once the config line is
        // seen — or, defensively, when the next header/task arrives or
        // input ends (a ROM that omits the config line then yields
        // activityType="", which [findRootTaskOnDisplay] treats as
        // not-a-valid-target — fail-safe, never a bad move-task).
        var pending: RootTaskRow? = null
        fun flushPending() {
            pending?.let { roots += it }
            pending = null
        }
        for (line in amStackList.lineSequence()) {
            val rm = ROOT_RX.find(line)
            if (rm != null) {
                flushPending()
                val rid = rm.groupValues[1].toIntOrNull()
                val did = rm.groupValues[2].toIntOrNull()
                val uid = rm.groupValues[3].toIntOrNull() ?: 0
                if (rid != null && did != null) {
                    pending = RootTaskRow(
                        rootTaskId = rid,
                        displayId = did,
                        activityType = "",
                        userId = uid,
                    )
                }
                currentRootTaskId = rid
                currentDisplay = did
                continue
            }
            if (pending != null && line.contains("configuration={")) {
                val at = ACTIVITY_TYPE_RX.find(line)?.groupValues?.get(1)
                if (at != null) {
                    pending = pending!!.copy(activityType = at)
                }
                flushPending()
                continue
            }
            val tm = TASK_RX.find(line)
            if (tm != null && currentRootTaskId != null && currentDisplay != null) {
                flushPending()
                val taskId = tm.groupValues[1].toIntOrNull() ?: continue
                val pkg = tm.groupValues[2]
                if (pkg.isEmpty()) continue
                val rest = tm.groupValues[3]
                val visible = rest.contains("visible=true")
                tasks += TaskRow(
                    taskId = taskId,
                    rootTaskId = currentRootTaskId,
                    displayId = currentDisplay,
                    packageName = pkg,
                    isForeground = visible,
                )
            }
        }
        flushPending()
        return StackSnapshot(tasks = tasks, rootTasks = roots)
    }

    /** Convenience for callers that only care about task rows. */
    fun parseAll(amStackList: String): List<TaskRow> = parse(amStackList).tasks

    /** First task for [packageName] anywhere, or null. Used by the
     *  Migrate branch + the legacy `pkg.move` path. */
    fun findAnyDisplay(rows: List<TaskRow>, packageName: String): TaskRow? =
        rows.firstOrNull { it.packageName == packageName }

    /** First task for [packageName] specifically on [displayId], or
     *  null. Used by the Resume branch. */
    fun findOnDisplay(
        rows: List<TaskRow>,
        packageName: String,
        displayId: Int,
    ): TaskRow? =
        rows.firstOrNull { it.packageName == packageName && it.displayId == displayId }

    /**
     * A RootTask on [displayId] that is a valid `am stack move-task`
     * **target** — i.e. a `standard`, current-user (`userId == 0`)
     * stack. `home` / `undefined` / cross-user stacks are skipped on
     * purpose: ATMS rejects reparenting a standard task into them
     * with `IllegalArgumentException: moveTaskToRootTask`. On
     * Leopard 8 the FSE display's only persistent stack is the
     * multi-user launcher **home** (`com.android.launcher3.fse`,
     * `mActivityType=home`) — blindly returning it is exactly the
     * "Driver→FSE / IVI→FSE-when-running fails with move-task hard
     * failure: uncaught_exception" bug.
     *
     * Returning null when no movable stack exists is the *correct*
     * signal: [doMove] then seeds its own `ClusterActivity`
     * (`standard`, `u0`) stack and reparents into THAT — the same
     * proven path the cluster display already uses successfully.
     */
    fun findRootTaskOnDisplay(roots: List<RootTaskRow>, displayId: Int): Int? =
        roots.firstOrNull {
            it.displayId == displayId &&
                it.activityType == "standard" &&
                it.userId == 0
        }?.rootTaskId

    /** Lookup the display a given taskId currently lives on. Mirrors
     *  the legacy `displayOfTask` helper. */
    fun displayOfTask(rows: List<TaskRow>, taskId: Int): Int? =
        rows.firstOrNull { it.taskId == taskId }?.displayId
}

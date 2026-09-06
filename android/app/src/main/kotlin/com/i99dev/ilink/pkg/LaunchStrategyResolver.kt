package com.i99dev.ilink.pkg

/**
 * Pure decision function: given the current task topology and a
 * launch request, pick the cheapest correct strategy. **No Android
 * imports, no shell calls, no state.** Hot-path cost is one O(N)
 * scan over the snapshot — N ≤ 20 in practice.
 *
 * Three outcomes:
 *
 *   * **[LaunchStrategy.Resume]** — package already has a task on
 *     the requested display. Bring it to front via
 *     `am stack move-task <taskId> <rootTaskId> true`. No new task,
 *     no `--activity-multiple-task`, no bounce-back risk.
 *   * **[LaunchStrategy.Migrate]** — package has a task on a
 *     *different* display. Reuse the existing `doMove` flow to
 *     reparent it onto the target display's stack.
 *   * **[LaunchStrategy.FreshLaunch]** — no task anywhere. Fall
 *     through to the legacy `am start --activity-multiple-task
 *     --display N` path + bounce-back recovery.
 *
 * This resolver is what fixes "I closed the app and re-launched it
 * from ilink and got a fresh instance from zero." The old code
 * unconditionally took the FreshLaunch path because
 * `--activity-multiple-task` was the only way to dodge snap-back —
 * but snap-back is only a concern when the package's existing task
 * is on a *different* display. When it's on the **same** display
 * we want to dodge, the existing task IS the target, and bringing
 * it to front is both cheaper and produces the user-visible "this
 * is the same instance I had open before" behaviour.
 */
sealed class LaunchStrategy {
    data class Resume(val taskId: Int, val rootTaskId: Int) : LaunchStrategy()
    data class Migrate(
        val taskId: Int,
        val fromDisplay: Int,
        val toDisplay: Int,
    ) : LaunchStrategy()
    object FreshLaunch : LaunchStrategy()
}

object LaunchStrategyResolver {

    /**
     * Resolve the cheapest strategy for landing [packageName] on
     * [targetDisplay], given the parsed task topology in [snapshot].
     *
     * The caller is responsible for any pre-checks that don't depend
     * on task topology — role gating, capability gating, DiShare
     * routing, default-display short-circuit. By the time we reach
     * this resolver, those have all said "yes, run an `am`-style
     * landing on display N."
     */
    fun resolve(
        packageName: String,
        targetDisplay: Int,
        snapshot: StackSnapshot,
    ): LaunchStrategy {
        val onTarget = AmStackParser.findOnDisplay(
            snapshot.tasks, packageName, targetDisplay,
        )
        if (onTarget != null) {
            return LaunchStrategy.Resume(
                taskId = onTarget.taskId,
                rootTaskId = onTarget.rootTaskId,
            )
        }
        val anywhere = AmStackParser.findAnyDisplay(snapshot.tasks, packageName)
        if (anywhere != null) {
            return LaunchStrategy.Migrate(
                taskId = anywhere.taskId,
                fromDisplay = anywhere.displayId,
                toDisplay = targetDisplay,
            )
        }
        return LaunchStrategy.FreshLaunch
    }
}

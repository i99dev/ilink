package com.i99dev.ilink.pkg

import android.content.Context

/**
 * THE single source of truth for "must this app be **fresh-launched
 * on the target display** instead of same-pid `move-stack`?".
 *
 * Why this exists: a cross-display move forces an Android Activity
 * recreate (display config delta). Well-behaved apps survive it and
 * keep the same pid (Spotify / Shaheen / Telegram — proven on-car,
 * persistent). ReVanced / ReVanced-patched builds DON'T: their
 * patched Activity re-targets the default display on recreate (and
 * NPEs on the retained first-run DialogFragment), so a `move-stack`
 * bounces them back to the IVI within ~5 s. For those, a fresh
 * launch directly on the target display is the only stable
 * placement (proven on L8: ReVanced YouTube `am start --display N`
 * held 25 s, zero crashes; new pid is unavoidable for them).
 *
 * Design (centralised, O(1), zero hot-path I/O — see [freshLaunchOnly]):
 *   * **rule** — an extensible list of package predicates. v1 = the
 *     ReVanced prefix. Adding a future category that bounces is one
 *     entry here and touches NOTHING else (not [doMove], not Flutter).
 *   * **userAdded** — packages the user marked (they saw an app
 *     bounce/crash). Persisted in [SharedPreferences]; mirrored into
 *     a `@Volatile` in-memory snapshot so the hot path never does
 *     disk I/O. Rebuilt ONLY on mutation.
 *   * effective verdict = `pkg ∈ userAdded ∨ rule(pkg)` — a pure
 *     function ([decide]) so it is unit-testable with no Android.
 *
 * The decision is consumed at exactly ONE site —
 * [PackagePlatformPlugin.doMove] — which both DiLink generations
 * reach (Di5.0 ShellLaunch→doMove + IviLocal→doMove return; Di5.1
 * handleMove→doMove; resolver Migrate→doMove). The Flutter side
 * (badge + settings) never re-implements the rule: it asks this
 * object through the `clusterPolicy.*` channel and renders the
 * answer.
 */
object ClusterLaunchPolicy {
    private const val PREFS = "cluster_launch_policy"
    private const val KEY_ADDED = "fresh_launch_added"

    /**
     * Extensible default rule set. A package is fresh-launch-only by
     * rule if ANY predicate matches. v1: ReVanced /
     * ReVanced-patched builds (`app.revanced.*`, `com.revanced.*`).
     * Add a predicate here for any future family that cannot survive
     * the cross-display recreate — no other file changes.
     */
    private val rules: List<(String) -> Boolean> = listOf(
        { p -> p.startsWith("app.revanced.") || p.startsWith("com.revanced.") },
    )

    /** `@Volatile` snapshot of the persisted user set. Published
     *  AFTER the disk write so a reader never sees an unpersisted
     *  value. The hot path reads only this — never disk. */
    @Volatile
    private var added: Set<String> = emptySet()

    @Volatile
    private var loaded = false

    /** True if any default [rules] predicate matches. */
    fun ruleHit(pkg: String): Boolean = rules.any { it(pkg) }

    /**
     * PURE effective verdict — the entire unit-test surface. No
     * Android, no I/O, no shared state: `pkg` is fresh-launch-only
     * iff the user added it or a default rule matches.
     */
    fun decide(pkg: String, userAdded: Set<String>): Boolean =
        pkg in userAdded || ruleHit(pkg)

    /**
     * Hot-path predicate, called from [PackagePlatformPlugin.doMove]
     * on every cross-display move. O(1) set lookup + the cheap rule
     * lambdas; zero allocation, zero disk I/O. [ensureLoaded] must
     * have run once (done at plugin init) — if it somehow hasn't,
     * `added` is empty and the rule still applies (safe default,
     * behaviour-identical to the original hardcoded heuristic).
     */
    fun freshLaunchOnly(pkg: String): Boolean = decide(pkg, added)

    /** Batched classify for the UI/badge: returns the subset of
     *  [pkgs] that are fresh-launch-only. One channel call per
     *  app-list refresh keeps the rule native (never duplicated in
     *  Dart) without per-icon round-trips. */
    fun freshLaunchSubset(pkgs: List<String>): List<String> =
        pkgs.filter(::freshLaunchOnly)

    /** Idempotent one-time load of the persisted user set into the
     *  in-memory snapshot. Called at plugin init so the hot path is
     *  never the first reader. */
    @Synchronized
    fun ensureLoaded(ctx: Context) {
        if (loaded) return
        added = read(ctx)
        loaded = true
    }

    /** The user-added set (loads on first use). For the settings UI
     *  to distinguish user entries from rule-matched ones. */
    fun userAdded(ctx: Context): Set<String> {
        ensureLoaded(ctx)
        return added
    }

    /** Mark [pkg] fresh-launch-only. Returns the new user set. */
    @Synchronized
    fun add(ctx: Context, pkg: String): Set<String> =
        mutate(ctx) { it + pkg }

    /** Un-mark a USER-added [pkg]. Rule-matched packages (e.g.
     *  ReVanced) are unaffected by this — the rule still applies;
     *  removing them is intentionally not supported in v1 (it would
     *  re-introduce a guaranteed bounce/crash). */
    @Synchronized
    fun remove(ctx: Context, pkg: String): Set<String> =
        mutate(ctx) { it - pkg }

    private fun mutate(
        ctx: Context,
        f: (Set<String>) -> Set<String>,
    ): Set<String> {
        ensureLoaded(ctx)
        val next = f(added)
        if (next != added) {
            ctx.applicationContext
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putStringSet(KEY_ADDED, next)
                .apply()
            // Publish to the hot path AFTER the write is queued.
            added = next
        }
        return next
    }

    private fun read(ctx: Context): Set<String> =
        ctx.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(KEY_ADDED, emptySet())
            ?.toSet()
            ?: emptySet()
}

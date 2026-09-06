package com.i99dev.ilink.nav.ingest

import android.view.accessibility.AccessibilityNodeInfo
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The single bolt-on seam between the shared `RemoteControlAccessibilityService`
 * and the nav sources. A source registers the packages it scrapes; the service
 * forwards each accessibility event here. The package set + view-ids live in the
 * sources (injected), NEVER hard-wired into the shared service (review fix).
 *
 * Cheap-gate contract: the service checks [activePackages] (a set lookup) BEFORE
 * fetching any node tree, so apps no nav source cares about cost nothing.
 */
object NavA11yDispatcher {

    private val handlers = CopyOnWriteArrayList<NavA11yHandler>()

    fun register(h: NavA11yHandler) {
        if (handlers.none { it === h }) handlers.add(h)
    }

    fun unregister(h: NavA11yHandler) {
        handlers.removeAll { it === h }
    }

    /** Union of every registered source's packages — the service's cheap event gate. */
    val activePackages: Set<String>
        get() = handlers.flatMapTo(HashSet()) { it.packages }

    /**
     * Dispatch a window's root to the source that owns [pkg]. Returns true when a source
     * actually consumed it.
     *
     * OWNERSHIP CHECK (the choke point): [root] must belong to [pkg]. A source reads
     * view-ids prefixed with the live package name, so a foreign tree yields nothing — but
     * it still burns that source's 200 ms self-throttle, which can starve a later read of
     * the *correct* tree. Dropping the mismatch here keeps every caller honest with one
     * check instead of three.
     */
    fun onWindow(pkg: String?, root: AccessibilityNodeInfo?): Boolean {
        if (pkg == null || root == null) return false
        val rootPkg = runCatching { root.packageName?.toString() }.getOrNull()
        if (!NavA11yReadPolicy.rootMatches(rootPkg, pkg)) return false
        val handler = handlers.firstOrNull { pkg in it.packages } ?: return false
        runCatching { handler.onWindow(root, pkg) }
        return true
    }
}

/** A nav source's a11y side: declares its [packages] and scrapes a window root. */
interface NavA11yHandler {
    val packages: Set<String>

    /** Called (on the a11y thread) when one of [packages] is foreground. The
     *  handler must self-throttle (the ground-truth cadence is 200 ms/app). */
    fun onWindow(root: AccessibilityNodeInfo, pkg: String)
}

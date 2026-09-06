package com.i99dev.ilink.adb

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

/**
 * Lifecycle phases of the loopback-ADB + DashDaemon bring-up.
 *
 * Steady-state is [Idle] (with the daemon already up; the bus simply
 * never emits during fast-path ping-success). The Authorizing phase
 * is the moment the system "Allow USB debugging?" prompt is most
 * likely about to fire; the Dart side renders a contextual card
 * underneath the system prompt at that moment.
 */
enum class AdbSetupPhase {
    /** Daemon up + connected, or no run in flight. Overlay hidden. */
    Idle,

    /**
     * About to open the loopback connection. The system prompt is
     * either already on screen or imminent. Overlay shows the
     * "Allow USB debugging" explainer.
     */
    Authorizing,

    /**
     * ADB connection established; spawning DashDaemon over the
     * loopback shell. Overlay flips to "Setting up".
     */
    Spawning,

    /** Daemon is bound and pinging. Overlay auto-dismisses. */
    Ready,

    /**
     * Bring-up failed. Overlay shows the error + a Try again
     * button (which calls [AdbSetupPlugin.retry]).
     */
    Failed,
}

/**
 * Process-wide bus that broadcasts [AdbSetupPhase] transitions from
 * [AdbShellBridge] to whatever wants to observe (currently
 * [AdbSetupPlugin] forwarding to Dart).
 *
 * Thread-safety: the current state is held in an [AtomicReference];
 * listeners are stored in a [CopyOnWriteArrayList] so iteration
 * during dispatch never collides with add/remove. Listener callbacks
 * run on the calling thread of [setState] — the plugin is responsible
 * for hopping to the platform thread before touching the EventSink.
 */
object AdbSetupBus {
    data class Snapshot(val phase: AdbSetupPhase, val error: String?)

    fun interface Listener {
        fun onChange(snapshot: Snapshot)
    }

    private val current = AtomicReference(Snapshot(AdbSetupPhase.Idle, null))
    private val listeners = CopyOnWriteArrayList<Listener>()

    fun snapshot(): Snapshot = current.get()

    fun setState(phase: AdbSetupPhase, error: String? = null) {
        val next = Snapshot(phase, error)
        val prev = current.getAndSet(next)
        // Skip identical transitions to avoid waking listeners on
        // duplicate state writes (e.g. two callers concurrently
        // entering ensureAdb both flag Authorizing).
        if (prev == next) return
        for (l in listeners) {
            try {
                l.onChange(next)
            } catch (_: Throwable) {
                // Listener errors must not propagate back into the
                // bridge call site that triggered the state change.
            }
        }
    }

    fun addListener(l: Listener) {
        listeners.add(l)
    }

    fun removeListener(l: Listener) {
        listeners.remove(l)
    }
}

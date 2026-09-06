package com.i99dev.ilink.nav.ingest

import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.domain.NavSourceId

/**
 * Static bridge between the system-bound [NavNotifListenerService] (Android owns
 * its lifecycle) and the [NotifNavSource]. The listener emits parsed frames here;
 * the source forwards them to the registry only while armed. Inert (and harmless)
 * when notification access isn't granted — the service simply never binds.
 */
object NavNotifBus {
    @Volatile private var sink: ((NavGuidance) -> Unit)? = null
    @Volatile private var goneSink: ((NavSourceId) -> Unit)? = null

    fun attach(s: (NavGuidance) -> Unit, gone: (NavSourceId) -> Unit) {
        sink = s
        goneSink = gone
    }

    fun detach() {
        sink = null
        goneSink = null
    }

    fun emit(frame: NavGuidance) {
        sink?.invoke(frame)
    }

    /** True while a [NotifNavSource] is attached (HUD armed). Lets the listener's
     *  keep-fresh re-emit ticker skip work when nothing consumes the frames. */
    fun hasSink(): Boolean = sink != null

    /** A known nav app's notification was removed → that app's navigation ended. */
    fun emitGone(source: NavSourceId) {
        goneSink?.invoke(source)
    }
}

/**
 * The universal "support most maps" source — one [android.service.notification.NotificationListenerService]
 * (see [NavNotifListenerService]) covers EVERY app in [NavAppRegistry] via the
 * standard notification extras + [com.i99dev.ilink.nav.logic.NavNotifParse].
 * Frames carry their own per-app [NavGuidance.source], so this single source
 * drives many apps through the registry/arbiter.
 *
 * Capability-probed: if the BYD ROM doesn't grant notification access the
 * listener never binds and this no-ops (the a11y sources still work).
 */
class NotifNavSource : NavSource {
    override val id: NavSourceId = NavSourceId.UNKNOWN // multi-app; frames self-tag
    override val ttlMs: Long = 10_000L

    override fun start(onFrame: (NavGuidance) -> Unit, onGone: (NavSourceId) -> Unit) {
        NavNotifBus.attach(onFrame, onGone)
    }

    override fun stop() {
        NavNotifBus.detach()
    }
}

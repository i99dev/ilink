package com.i99dev.ilink.voice

/** Coarse voice-assistant phase, mirrored from Dart's `AssistantPhase`
 *  (plus [tool] for "running a command"). The floating bubble renders a
 *  glyph/animation per phase so a backgrounded driver can tell what the
 *  assistant is doing. Wire strings must match `voice_phase.dart`. */
enum class VoicePhase {
    idle,
    connecting,
    listening,
    thinking,
    speaking,
    tool,
    error,
    ;

    companion object {
        fun fromWire(raw: String?): VoicePhase = when (raw) {
            "connecting" -> connecting
            "listening" -> listening
            "thinking" -> thinking
            "speaking" -> speaking
            "tool" -> tool
            "error" -> error
            else -> idle
        }
    }
}

/**
 * Process-local signal: what is the voice assistant doing right now?
 *
 * The fine-grained [phase] (+ [toolName]) is pushed from Dart via
 * [VoiceChannel] `setVoicePhase` across a session; [VoiceSessionService]
 * also sets a coarse active/idle as a fallback. Observed by
 * [com.i99dev.ilink.bubble.BubbleOverlayService], which renders the
 * matching glyph + earcon ONLY while backgrounded (the bubble only exists
 * then), so the override is silent/inert in the foreground where the full
 * Flutter UI is already on screen.
 *
 * Single-listener slot: exactly one bubble-overlay service instance is the
 * only observer. [setPhase] notifies on the caller's thread; the observer
 * marshals to its own handler.
 */
object VoiceActivityState {
    @Volatile
    var phase: VoicePhase = VoicePhase.idle
        private set

    @Volatile
    var toolName: String? = null
        private set

    /** True whenever a session is live (any non-idle phase). */
    val isActive: Boolean get() = phase != VoicePhase.idle

    @Volatile
    private var listener: ((VoicePhase, String?) -> Unit)? = null

    /** Register (or clear, with null) the single observer. The current
     *  [phase] is NOT pushed on register — observers read it directly after
     *  registering to pick up an already-running session. */
    fun setListener(l: ((VoicePhase, String?) -> Unit)?) {
        listener = l
    }

    /** Fine-grained update from the Dart side. */
    fun setPhase(phase: VoicePhase, toolName: String? = null) {
        if (this.phase == phase && this.toolName == toolName) return
        this.phase = phase
        this.toolName = toolName
        listener?.invoke(phase, toolName)
    }

    /** Coarse fallback used by [VoiceSessionService] start/stop: maps to
     *  [VoicePhase.connecting] / [VoicePhase.idle]. The Dart push refines it
     *  to the real phase moments later. On stop we always force idle (and
     *  clear any tool) so a torn-down session never leaves the bubble lit. */
    fun setActive(active: Boolean) {
        if (active) {
            if (phase == VoicePhase.idle) setPhase(VoicePhase.connecting)
        } else {
            setPhase(VoicePhase.idle)
        }
    }
}

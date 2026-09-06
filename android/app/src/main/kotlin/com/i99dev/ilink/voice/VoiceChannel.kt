package com.i99dev.ilink.voice

import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Dart-facing seam for voice-session-aware platform concerns:
 *   - start/stop the foreground service that keeps the Flutter engine
 *     alive while the user is in another app
 *   - deliver hardware-key presses (steering-wheel voice button) +
 *     VOICE_COMMAND/ASSIST intents to the VoiceController
 *   - deliver audio-focus changes so a transient Spotify interruption
 *     can pause (not kill) the session
 *
 * Method names + event types are mirrored by the contract test in Dart —
 * adding or renaming a method requires the same change on both sides.
 */
class VoiceChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        const val METHOD_CHANNEL = "ilink/voice"
        const val EVENT_CHANNEL = "ilink/voice/events"
        const val TAG = "VoiceChannel"

        // Event types pushed on the EventChannel. Dart must match these
        // strings — see voice_service_bridge.dart.
        const val EVENT_HARDWARE_KEY = "hardwareKey"
        const val EVENT_AUDIO_FOCUS_LOSS = "audioFocusLoss"
        const val EVENT_AUDIO_FOCUS_LOSS_TRANSIENT = "audioFocusLossTransient"
        const val EVENT_AUDIO_FOCUS_GAIN = "audioFocusGain"
        const val EVENT_SERVICE_KILLED = "serviceKilled"
    }

    private val method = MethodChannel(messenger, METHOD_CHANNEL)
    private val events = EventChannel(messenger, EVENT_CHANNEL)
    private var sink: EventChannel.EventSink? = null

    fun register() {
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
                sink = eventSink
                VoiceSessionService.bindEventSink(eventSink)
            }
            override fun onCancel(arguments: Any?) {
                VoiceSessionService.bindEventSink(null)
                sink = null
            }
        })
        method.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "startService" -> {
                        VoiceSessionService.start(context)
                        result.success(mapOf("ok" to true))
                    }
                    "stopService" -> {
                        VoiceSessionService.stop(context)
                        result.success(mapOf("ok" to true))
                    }
                    "setNotificationText" -> {
                        val text = call.argument<String>("text") ?: ""
                        VoiceSessionService.updateNotificationText(context, text)
                        result.success(mapOf("ok" to true))
                    }
                    "setVoicePhase" -> {
                        // Fine-grained phase for the background bubble +
                        // earcons. No-op visually when foregrounded (the
                        // bubble isn't shown), so it's cheap to always push.
                        VoiceActivityState.setPhase(
                            VoicePhase.fromWire(call.argument<String>("phase")),
                            call.argument<String>("tool"),
                        )
                        result.success(mapOf("ok" to true))
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.e(TAG, "channel error in ${call.method}: ${e.message}", e)
                result.error(e.javaClass.simpleName, e.message, null)
            }
        }
    }

    /** Fire a hardware-key / voice-intent event to Dart. Safe to call before
     *  Dart has subscribed — the event is dropped. */
    fun pushHardwareKey() {
        sink?.success(mapOf("type" to EVENT_HARDWARE_KEY))
    }

    /** Forward a VOICE_COMMAND / ASSIST intent as a hardware-key event —
     *  Dart treats both as "user asked for the assistant from outside the app". */
    fun forwardVoiceIntent(intent: Intent?) {
        val action = intent?.action ?: return
        if (action == Intent.ACTION_VOICE_COMMAND || action == Intent.ACTION_ASSIST) {
            pushHardwareKey()
        }
    }
}

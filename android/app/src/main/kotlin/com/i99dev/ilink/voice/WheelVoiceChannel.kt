package com.i99dev.ilink.voice

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Dart-facing control for the dynamic steering-wheel voice override.
 *
 * The native [WheelVoiceController] is the single source of truth for the
 * enable flag (it's what the accessibility key filter consults), so the
 * Settings toggle reads + writes it through here rather than keeping a
 * second copy in Dart `AppSettings`. Reads/writes are SharedPreferences
 * only — cheap, main-thread-safe.
 *
 * Methods (mirrored in `wheel_voice_bridge.dart`):
 *   - `isOverrideEnabled` → Bool
 *   - `setOverrideEnabled` (`enabled: Bool`) → {ok: true}
 *   - `resolvedKey` → {label, scanCode, deviceNode, keyLayout} | null
 *     (diagnostics: what the resolver found on this car, for a settings
 *     subtitle / support report)
 */
class WheelVoiceChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        const val CHANNEL = "ilink/wheel_voice"
        private const val TAG = "WheelVoiceChannel"
    }

    private val channel = MethodChannel(messenger, CHANNEL)

    fun register() {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isOverrideEnabled" ->
                        result.success(WheelVoiceController.isEnabled(context))
                    "setOverrideEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        WheelVoiceController.setEnabled(context, enabled)
                        result.success(mapOf("ok" to true))
                    }
                    "resolvedKey" -> {
                        val k = WheelVoiceController.resolvedKey()
                        result.success(
                            k?.let {
                                mapOf(
                                    "label" to it.label,
                                    "scanCode" to it.scanCode,
                                    "deviceNode" to it.deviceNode,
                                    "keyLayout" to it.keyLayout,
                                )
                            },
                        )
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                Log.w(TAG, "channel error in ${call.method}: ${t.message}", t)
                result.error("wheel_voice_error", t.message, null)
            }
        }
    }
}

package com.i99dev.ilink.adb

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges [AdbSetupBus] to Dart so the in-app contextual overlay can
 * paint itself underneath the system "Allow USB debugging?" prompt
 * BEFORE that prompt fires.
 *
 * Channels:
 *   * `ilink/adb_setup` — method channel.
 *       - `getCurrent` → `{phase: String, error: String?}` snapshot.
 *       - `retry` → close + re-run [AdbShellBridge.ensureDaemon] on a
 *         worker thread. Resolves with the post-retry snapshot.
 *   * `ilink/adb_setup/events` — event channel; emits the same
 *     snapshot map on every transition.
 *
 * Threading: bus listeners fire on the bridge's calling thread (often
 * a background worker). We hop to the main thread before touching the
 * EventSink because Flutter's EventSink is not thread-safe.
 */
class AdbSetupPlugin(
    private val context: Context,
) {
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val listener = AdbSetupBus.Listener { snap ->
        // Hop to the platform thread — EventSink calls from arbitrary
        // worker threads can crash the engine.
        mainHandler.post {
            sink?.success(snap.toMap())
        }
    }

    fun register(messenger: BinaryMessenger) {
        val mc = MethodChannel(messenger, METHOD_CHANNEL)
        mc.setMethodCallHandler(::onMethodCall)
        methodChannel = mc

        val ec = EventChannel(messenger, EVENT_CHANNEL)
        ec.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
                // Seed the new listener with the current snapshot so a
                // late-attaching Dart consumer doesn't have to round-
                // trip getCurrent() before painting anything.
                events?.success(AdbSetupBus.snapshot().toMap())
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
        eventChannel = ec

        AdbSetupBus.addListener(listener)
    }

    fun unregister() {
        AdbSetupBus.removeListener(listener)
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        sink = null
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCurrent" -> result.success(AdbSetupBus.snapshot().toMap())
            "retry" -> {
                Thread({
                    try {
                        // Force a fresh state — close drops the live
                        // ADB connection so ensureDaemon goes through
                        // the full Authorizing → Spawning → Ready path
                        // and the bus broadcasts every transition.
                        AdbShellBridge.close()
                        AdbShellBridge.ensureDaemon(maxAttempts = 1)
                        val snap = AdbSetupBus.snapshot().toMap()
                        mainHandler.post { result.success(snap) }
                    } catch (t: Throwable) {
                        mainHandler.post {
                            result.error(
                                "RETRY_THREW",
                                "${t.javaClass.simpleName}: ${t.message}",
                                null,
                            )
                        }
                    }
                }, "adb-setup-retry").apply { isDaemon = true }.start()
            }
            else -> result.notImplemented()
        }
    }

    private fun AdbSetupBus.Snapshot.toMap(): Map<String, Any?> = mapOf(
        "phase" to phase.name,
        "error" to error,
    )

    companion object {
        private const val METHOD_CHANNEL = "ilink/adb_setup"
        private const val EVENT_CHANNEL = "ilink/adb_setup/events"
    }
}

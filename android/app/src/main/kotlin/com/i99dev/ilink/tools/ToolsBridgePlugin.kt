package com.i99dev.ilink.tools

import android.os.Handler
import android.os.Looper
import com.i99dev.ilink.adb.AdbShellBridge
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Method channel for the Tools + AppActions features.
 *
 * Single method:
 *   * `exec` ({argv: List<String>, timeoutMs: Int?}) → String stdout
 *
 * argv joining policy lives here so the Dart side never has to care
 * about quoting. We single-quote each argv element and join with
 * spaces; embedded single quotes are escaped via the `'\''` shell
 * idiom. This matches what the reference shell calls appear to do.
 *
 * Threading: the underlying AdbShellBridge.shell() blocks on a
 * worker thread — adb shell calls take 5-50ms. We dispatch on a
 * fresh worker per request to keep concurrent calls (Tools poll +
 * AppActions sheet open) from serialising on the bridge's internal
 * mutex; the bridge already serialises adb writes itself.
 */
class ToolsBridgePlugin {
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, CHANNEL)
        ch.setMethodCallHandler(::onMethodCall)
        channel = ch
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "exec" -> {
                @Suppress("UNCHECKED_CAST")
                val argv = call.argument<List<String>>("argv")
                if (argv.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "argv must be non-empty list", null)
                    return
                }
                val timeoutMs = (call.argument<Int>("timeoutMs") ?: 5000).toLong()
                val cmd = joinShellSafe(argv)
                Thread({
                    try {
                        val out = AdbShellBridge.shell(cmd, timeoutMs)
                        mainHandler.post { result.success(out) }
                    } catch (t: Throwable) {
                        mainHandler.post {
                            result.error(
                                "SHELL_THREW",
                                "${t.javaClass.simpleName}: ${t.message}",
                                null,
                            )
                        }
                    }
                }, "tools-shell-${argv[0]}").apply { isDaemon = true }.start()
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Single-quote each argv element to defeat shell injection. Every
     * embedded single-quote is escaped with the canonical `'\''` form
     * (close, escaped quote, reopen). Numeric tokens and bare flags
     * pass through quoting safely; flags like `--user 0` join cleanly.
     *
     * Worth knowing: this means callers MUST split flags from values
     * (`['--user', '0']`, not `['--user 0']`) — the platform doesn't
     * second-guess your argv vector.
     */
    private fun joinShellSafe(argv: List<String>): String {
        return argv.joinToString(" ") { tok ->
            if (tok.isEmpty()) "''"
            else "'" + tok.replace("'", "'\\''") + "'"
        }
    }

    companion object {
        private const val CHANNEL = "ilink/tools_shell"
    }
}

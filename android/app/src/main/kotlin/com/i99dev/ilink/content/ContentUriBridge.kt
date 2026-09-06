package com.i99dev.ilink.content

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.Executors

/**
 * Tiny MethodChannel that reads a `content://` URI into UTF-8 text.
 *
 * Why this exists: when the user taps a `.m3u` in a file manager and
 * picks "Open with ilink", Android delivers an ACTION_VIEW intent
 * whose data URI is overwhelmingly `content://...` (Storage Access
 * Framework). Dart's `dart:io File` can't open content URIs — only
 * absolute file paths — so the BYO importer needs a way to materialise
 * the bytes via [android.content.ContentResolver.openInputStream].
 * That requires a Context, which means: native.
 *
 * Scope: the smallest possible bridge — one method, one channel, one
 * worker thread. Sibling of [NetworkInfoChannel] /
 * [HomeScreenShortcutHandler]: each MethodChannel handler is a
 * single-responsibility class registered from [MainActivity.onCreate].
 *
 * Safety:
 *   * Reads happen off the UI thread. Even modest content URIs go
 *     through a ContentResolver round-trip; blocking the platform
 *     thread risks ANRs (the rest of the engine is on the same loop).
 *   * Hard upper bound of [MAX_BYTES] = 16 MB. Larger payloads return
 *     `PAYLOAD_TOO_LARGE` rather than OOMing the heap. M3U files in
 *     this app's universe top out at ~80 MB and we cap stations at
 *     5 000 anyway; 16 MB is far more than any sane playlist.
 *   * UTF-8 only. M3U / EXTINF spec is text; non-UTF-8 bytes throw
 *     `DECODE_FAILED` which the importer surfaces as a friendly
 *     "couldn't read this file" SnackBar.
 *
 * No state, no caches, no streams — the file is loaded fully before
 * the Future resolves. That matches the importer's expectations and
 * keeps lifecycle simple: nothing to dispose, nothing to leak.
 */
class ContentUriBridge(private val context: Context) {
    companion object {
        const val CHANNEL = "com.i99dev.ilink/content_uri"

        /** Refuse to allocate a String for anything beyond this — a
         *  malicious or accidental giant payload should fail loudly,
         *  not silently consume the IVI's heap. */
        const val MAX_BYTES = 16 * 1024 * 1024
    }

    private var channel: MethodChannel? = null

    /** Single-threaded so concurrent reads serialise — keeps the
     *  ContentResolver's per-thread overhead bounded and means a slow
     *  read can't starve the channel with a backlog. */
    private val ioExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "ContentUriBridge-IO").apply { isDaemon = true }
    }

    private val main = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also { ch ->
            ch.setMethodCallHandler(::onCall)
        }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "readText" -> {
                val uriStr = call.argument<String>("uri")
                if (uriStr.isNullOrBlank()) {
                    result.error("INVALID_URI", "uri argument missing", null)
                    return
                }
                ioExecutor.execute { readText(uriStr, result) }
            }
            else -> result.notImplemented()
        }
    }

    private fun readText(uriStr: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(uriStr)
            context.contentResolver.openInputStream(uri).use { input ->
                if (input == null) {
                    reply { result.error("NOT_FOUND", "no stream for $uriStr", null) }
                    return
                }
                // Cap the read at MAX_BYTES + 1 so we can detect overruns
                // without buffering the entire over-sized payload.
                val bytes = ByteArray(MAX_BYTES + 1)
                var off = 0
                while (off < bytes.size) {
                    val n = input.read(bytes, off, bytes.size - off)
                    if (n <= 0) break
                    off += n
                }
                if (off > MAX_BYTES) {
                    reply {
                        result.error(
                            "PAYLOAD_TOO_LARGE",
                            "exceeds ${MAX_BYTES / (1024 * 1024)} MB cap",
                            null,
                        )
                    }
                    return
                }
                val text = try {
                    String(bytes, 0, off, Charsets.UTF_8)
                } catch (_: Exception) {
                    reply { result.error("DECODE_FAILED", "not UTF-8", null) }
                    return
                }
                reply { result.success(text) }
            }
        } catch (e: SecurityException) {
            // The content provider revoked our temporary URI permission
            // — usually because the activity was relaunched and the
            // grant was scoped to the original launch.
            reply { result.error("PERMISSION_DENIED", e.message, null) }
        } catch (e: IOException) {
            reply { result.error("IO_ERROR", e.message, null) }
        } catch (e: Exception) {
            reply { result.error("UNKNOWN", e.message, e.toString()) }
        }
    }

    /** MethodChannel.Result must be replied from the main thread per
     *  the Flutter docs — hop back from the IO executor here. */
    private fun reply(block: () -> Unit) {
        main.post(block)
    }
}

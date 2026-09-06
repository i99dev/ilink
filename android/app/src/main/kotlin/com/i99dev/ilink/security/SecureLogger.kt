package com.i99dev.ilink.security

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.SecretKey
import kotlin.random.Random

/**
 * Append-only encrypted event log. Sits behind every sensitive side-effect
 * on dash (car command dispatch, rate-limiter bursts, integrity failures)
 * so post-incident forensics has a truth stream without ever persisting a
 * plaintext command id on disk.
 *
 * Guarantees:
 *   - **Cleartext command ids and args never touch disk.** Callers are
 *     expected to hash them (SHA-256) before emitting — the `emit` helper
 *     accepts only already-opaque strings.
 *   - **Dispatch path is non-blocking.** `emit()` enqueues and returns;
 *     the flusher drains on its own thread every `FLUSH_PERIOD_MS` or
 *     when the queue depth crosses `FLUSH_BATCH_SIZE`.
 *   - **File rotation** at `MAX_FILE_BYTES`; retained for `RETENTION_DAYS`.
 *
 * This is the Kotlin/javax.crypto baseline. Phase 3 NDK replaces the
 * encryption with native code + mlock'd plaintext buffer; the `emit` /
 * `sha256Hex` callers don't notice.
 */
class SecureLogger internal constructor(
    private val logDir: File,
    private val key: SecretKey,
    private val scheduler: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "dash-secure-logger").apply { isDaemon = true }
        },
) {
    companion object {
        private const val TAG = "SecureLogger"
        private const val FLUSH_PERIOD_MS = 1_000L
        private const val FLUSH_BATCH_SIZE = 64
        private const val MAX_FILE_BYTES = 1_000_000L
        private const val RETENTION_DAYS = 7L
        private const val FILE_PREFIX = "dash-events-"
        private const val FILE_SUFFIX = ".bin"

        @Volatile private var instance: SecureLogger? = null

        fun init(context: Context): SecureLogger {
            instance?.let { return it }
            synchronized(this) {
                instance?.let { return it }
                val dir = File(context.filesDir, "events").apply { mkdirs() }
                val key = DeviceKeyMaterial.fromContext(context).deriveDeviceKey()
                val logger = SecureLogger(dir, key)
                logger.start()
                instance = logger
                return logger
            }
        }

        fun get(): SecureLogger? = instance

        /** Convenience for callers — shared helper so hashing is consistent. */
        fun sha256Hex(input: String): String {
            val d = CryptoUtils.sha256(input.toByteArray(Charsets.UTF_8))
            val sb = StringBuilder(d.size * 2)
            for (b in d) sb.append(String.format("%02x", b))
            return sb.toString()
        }
    }

    private val queue = ConcurrentLinkedQueue<JSONObject>()
    private val running = AtomicBoolean(false)

    fun start() {
        if (!running.compareAndSet(false, true)) return
        scheduler.scheduleWithFixedDelay(
            { flushSafely() },
            FLUSH_PERIOD_MS,
            FLUSH_PERIOD_MS,
            TimeUnit.MILLISECONDS,
        )
        // Housekeeping thread — once a minute, drop files older than retention.
        scheduler.scheduleWithFixedDelay(
            { sweepOldFilesSafely() },
            60_000L,
            60_000L,
            TimeUnit.MILLISECONDS,
        )
    }

    /**
     * Append an event. Caller has already hashed sensitive fields (command
     * id, args). Do NOT pass raw command text — there's no privacy budget
     * for that.
     */
    fun emit(event: JSONObject) {
        event.put("ts", System.currentTimeMillis())
        queue.offer(event)
        if (queue.size >= FLUSH_BATCH_SIZE) {
            scheduler.execute { flushSafely() }
        }
    }

    /** Command-dispatch event — used by the router. */
    fun emitDispatch(cmdHash: String, argsHash: String, outcome: String, latencyMs: Long) {
        emit(JSONObject().apply {
            put("kind", "dispatch")
            put("cmd", cmdHash)
            put("args", argsHash)
            put("outcome", outcome)
            put("latency_ms", latencyMs)
        })
    }

    /** One event per burst (not per rejected call). Called by the limiter. */
    fun emitBurst(rateClass: String, started: Boolean) {
        emit(JSONObject().apply {
            put("kind", "rate_burst")
            put("class", rateClass)
            put("started", started)
        })
    }

    /** Integrity check failure — fired by IntegrityMonitor. */
    fun emitIntegrity(subject: String, expectedSha: String, actualSha: String) {
        emit(JSONObject().apply {
            put("kind", "integrity")
            put("subject", subject)
            put("expected", expectedSha)
            put("actual", actualSha)
        })
    }

    // --- internals ---

    private fun flushSafely() {
        try {
            flush()
        } catch (t: Throwable) {
            Log.w(TAG, "flush failed: ${t.message}")
        }
    }

    private fun flush() {
        if (queue.isEmpty()) return
        val batch = StringBuilder()
        while (true) {
            val ev = queue.poll() ?: break
            batch.append(ev.toString()).append('\n')
            if (batch.length > 64_000) break // avoid giant cipher-text frames
        }
        if (batch.isEmpty()) return
        val plaintext = batch.toString().toByteArray(Charsets.UTF_8)
        val nonce = ByteArray(12).also { Random.Default.nextBytes(it) }
        val frame = CryptoUtils.encryptAesGcm(plaintext, key, nonce)
        val out = currentFile()
        out.appendBytes(framedPayload(frame))
    }

    /**
     * On-disk frame: big-endian 4-byte length || ciphertext (nonce + ct + tag).
     * Simple length-prefix so the uploader can stream frames back without
     * parsing a container format.
     */
    private fun framedPayload(frame: ByteArray): ByteArray {
        val len = frame.size
        val header = byteArrayOf(
            ((len ushr 24) and 0xff).toByte(),
            ((len ushr 16) and 0xff).toByte(),
            ((len ushr 8) and 0xff).toByte(),
            (len and 0xff).toByte(),
        )
        return header + frame
    }

    private fun currentFile(): File {
        val active = logDir.listFiles { f ->
            f.name.startsWith(FILE_PREFIX) && f.name.endsWith(FILE_SUFFIX)
        }?.maxByOrNull { it.lastModified() }
        if (active != null && active.length() < MAX_FILE_BYTES) return active
        return File(logDir, "$FILE_PREFIX${System.currentTimeMillis()}$FILE_SUFFIX")
    }

    private fun sweepOldFilesSafely() {
        try {
            val cutoff = System.currentTimeMillis() -
                TimeUnit.DAYS.toMillis(RETENTION_DAYS)
            logDir.listFiles()?.forEach { f ->
                if (f.lastModified() < cutoff) {
                    f.delete()
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "sweep failed: ${t.message}")
        }
    }
}

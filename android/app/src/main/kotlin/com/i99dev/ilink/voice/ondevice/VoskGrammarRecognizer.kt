package com.i99dev.ilink.voice.ondevice

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean

/**
 * On-device, grammar-constrained speech recognizer (Vosk / Kaldi) — the
 * Phase-1b engine behind the Dart `OnDeviceRecognizer` seam.
 *
 * Loads a Kaldi model from a filesystem path ([VoskModelStore]) and
 * constrains decoding to a grammar — the JSON phrase list produced by the
 * Dart-side `VoiceGrammar.toVoskGrammarJson()` (derived from the ONE
 * CarCommand registry). Grammar-constrained decoding is near-instant and
 * accurate over the fixed command + wake-phrase set, and the trailing
 * `[unk]` token makes out-of-grammar speech resolve to "unknown" (a clean
 * miss) instead of being force-fit to the nearest phrase.
 *
 * **Two-tier fallback (Arabic).** Vosk's MSA model mishears dialectal /
 * out-of-grammar speech — exactly the `[unk]` case. When [fallbackEnabled]
 * is set, this recognizer OWNS its own [AudioRecord] (instead of Vosk's
 * `SpeechService`) so it can keep the raw PCM of the utterance in flight. On
 * an `[unk]`/empty FINAL it hands that PCM to [onUtteranceMiss]; the Dart
 * layer runs Moonshine (sherpa-onnx) over it and resolves the transcript via
 * the fuzzy intent matcher. A Vosk HIT never invokes the fallback, so the
 * fast-path stays sub-300ms; the heavier Moonshine pass only runs on a miss.
 *
 * Still THE single always-on mic owner (M3): one [AudioRecord], opened on
 * [start] and released on [stop]. A cloud turn that needs the mic must [stop]
 * this first and restart after — that handoff lives in the service/arbiter
 * that owns this recognizer, never here.
 *
 * Pure engine wrapper: no Android UI, no platform-channel knowledge, so it
 * stays unit-reasoned and reusable across trims.
 */
class VoskGrammarRecognizer(private val sampleRate: Int = 16_000) {

    companion object {
        private const val TAG = "VoskRecognizer"

        /** ~0.12 s of 16 kHz mono audio per read — small enough for snappy
         *  partials, large enough to keep the JNI call rate sane. */
        private const val FRAMES_PER_READ = 1_920

        /** Don't ship a "miss" to the fallback unless we captured at least
         *  this much speech (~0.3 s) — guards against silence/noise blips. */
        private const val MIN_MISS_BYTES = 16_000 * 2 / 3

        /** Hard cap on a single utterance buffer (~15 s) so a stuck VAD
         *  boundary can never grow the buffer without bound. */
        private const val MAX_UTTERANCE_BYTES = 16_000 * 2 * 15
    }

    private var model: Model? = null
    private var recognizer: Recognizer? = null

    @Volatile
    private var fallbackEnabled = false

    private val running = AtomicBoolean(false)
    private var thread: Thread? = null
    private var record: AudioRecord? = null

    /**
     * Load [modelPath] and (re)build the recognizer constrained to
     * [grammarJson]. Re-callable to swap the grammar (e.g. after a
     * registry/config change) — tears down the previous recognizer first.
     */
    fun load(modelPath: String, grammarJson: String) {
        close()
        val m = Model(modelPath)
        model = m
        recognizer = Recognizer(m, sampleRate.toFloat(), grammarJson)
        Log.w(TAG, "loaded model=$modelPath grammarChars=${grammarJson.length}")
    }

    /**
     * Enable/disable the Moonshine fallback for this session. When false the
     * utterance PCM is never buffered (zero overhead for languages with no
     * fallback); when true an `[unk]` final emits the buffer to
     * `onUtteranceMiss`. Set by the integration layer from the active
     * [VoiceModelEntry]'s fallback descriptor BEFORE [start].
     */
    fun setFallbackEnabled(enabled: Boolean) {
        fallbackEnabled = enabled
    }

    /**
     * Begin continuous recognition on a dedicated capture thread. [onText] is
     * invoked with `(text, isFinal)` — partials drive the live HUD, finals
     * feed the matcher; out-of-grammar / `[unk]` results are filtered here so
     * callers only ever see real candidate utterances. [onUtteranceMiss] is
     * invoked with the raw 16-bit little-endian PCM of an utterance that Vosk
     * rejected (`[unk]`/empty) — only when [fallbackEnabled].
     */
    fun start(
        onText: (String, Boolean) -> Unit,
        onUtteranceMiss: (ByteArray) -> Unit,
        onError: (String) -> Unit,
    ) {
        val rec = recognizer
        if (rec == null) {
            onError("recognizer_not_loaded")
            return
        }
        if (running.getAndSet(true)) {
            Log.w(TAG, "start ignored — already running")
            return
        }
        val minBuf = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) {
            running.set(false)
            onError("audiorecord_unsupported")
            return
        }
        val ar = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                // Double the min so a slow JNI/Moonshine pass can't drop frames.
                maxOf(minBuf * 2, FRAMES_PER_READ * 2 * 2),
            )
        } catch (t: Throwable) {
            running.set(false)
            onError("audiorecord_init_failed: ${t.message}")
            return
        }
        if (ar.state != AudioRecord.STATE_INITIALIZED) {
            running.set(false)
            ar.release()
            onError("audiorecord_uninitialized")
            return
        }
        record = ar
        thread = Thread({ loop(rec, ar, onText, onUtteranceMiss, onError) }, "vosk-capture").apply {
            priority = Thread.MAX_PRIORITY - 1
            start()
        }
        Log.w(TAG, "listening (fallback=$fallbackEnabled)")
    }

    private fun loop(
        rec: Recognizer,
        ar: AudioRecord,
        onText: (String, Boolean) -> Unit,
        onUtteranceMiss: (ByteArray) -> Unit,
        onError: (String) -> Unit,
    ) {
        val shorts = ShortArray(FRAMES_PER_READ)
        // One reusable byte staging buffer for the short→LE-byte copy.
        val stage = ByteArray(FRAMES_PER_READ * 2)
        val utterance = ByteArrayOutputStream()
        try {
            ar.startRecording()
            rec.reset()
            while (running.get()) {
                val n = ar.read(shorts, 0, shorts.size)
                if (n <= 0) {
                    if (n == AudioRecord.ERROR_INVALID_OPERATION || n == AudioRecord.ERROR_BAD_VALUE) {
                        onError("audiorecord_read_error_$n")
                        break
                    }
                    continue
                }
                if (fallbackEnabled && utterance.size() < MAX_UTTERANCE_BYTES) {
                    for (i in 0 until n) {
                        val s = shorts[i].toInt()
                        stage[i * 2] = (s and 0xFF).toByte()
                        stage[i * 2 + 1] = ((s shr 8) and 0xFF).toByte()
                    }
                    utterance.write(stage, 0, n * 2)
                }
                if (rec.acceptWaveForm(shorts, n)) {
                    val text = textOf(rec.result, "text")
                    if (text != null) {
                        onText(text, true)
                    } else if (fallbackEnabled && utterance.size() >= MIN_MISS_BYTES) {
                        onUtteranceMiss(utterance.toByteArray())
                    }
                    utterance.reset() // utterance boundary — start fresh
                } else {
                    textOf(rec.partialResult, "partial")?.let { onText(it, false) }
                }
            }
        } catch (t: Throwable) {
            if (running.get()) onError(t.message ?: "capture_loop_error")
        } finally {
            runCatching { ar.stop() }
            runCatching { ar.release() }
        }
    }

    /** Stop recognition + release the AudioRecord this owns. Idempotent. */
    fun stop() {
        running.set(false)
        thread?.let {
            runCatching { it.join(1_500) }
        }
        thread = null
        // The loop's finally releases `record`; null it so close() is clean.
        record = null
    }

    /** Full teardown: stop + free the native recognizer + model. */
    fun close() {
        stop()
        recognizer?.close()
        recognizer = null
        model?.close()
        model = null
    }

    /** Extract the [key] field ("partial"/"text") from a Vosk result JSON,
     *  or null when empty / out-of-grammar (`[unk]`). */
    private fun textOf(hypothesis: String?, key: String): String? {
        if (hypothesis.isNullOrBlank()) return null
        return try {
            val t = JSONObject(hypothesis).optString(key, "").trim()
            if (t.isEmpty() || t == "[unk]") null else t
        } catch (t: Throwable) {
            null
        }
    }
}

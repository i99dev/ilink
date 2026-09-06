package com.i99dev.ilink.security

import android.content.Context
import android.util.Log
import com.i99dev.ilink.BuildConfig
import com.i99dev.ilink.device.DeviceEnv
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Periodic tamper check on staged unit DEX files + the dash process itself.
 *
 * Current checks (60s cadence):
 *   - Each declared unit DEX: compare on-disk SHA-256 against the manifest
 *     shipped in the APK. Gate by file `lastModified()` — if mtime is
 *     unchanged since last check, skip the re-hash (cheap).
 *   - Five independent tamper probes via [TamperProbes]: TracerPid,
 *     /proc/self/maps scan, /proc/net/tcp port scan, thread-name scan,
 *     timing canary. Trigger tamper only when ≥ 2 probes fire — each
 *     single probe is a one-line Frida bypass, but two uncorrelated
 *     signals firing is the live-instrumentation threshold.
 *
 * Reaction: flip `isHealthy` to false. `CarChannel.daemonStatus` surfaces
 * this to Dart so the UI can warn and the router can refuse to dispatch.
 * Events land in [SecureLogger] as `kind=integrity`, providing local diagnostics for a trail without exposing plaintext command history.
 *
 * Designed so the NDK version (plan Phase 3) is a drop-in: when the NDK
 * module lands, the SHA + probe implementations move into `secrets.so`
 * and this class's public surface is unchanged.
 */
class IntegrityMonitor private constructor(
    private val context: Context,
    private val logger: SecureLogger?,
) {
    companion object {
        private const val TAG = "IntegrityMonitor"
        private const val CHECK_PERIOD_SEC = 60L
        private const val MANIFEST_ASSET = "units/manifest.json"
        private const val STAGE_DIR = "/data/local/tmp"
        private const val TAMPER_THRESHOLD = 2

        @Volatile private var instance: IntegrityMonitor? = null

        fun init(context: Context): IntegrityMonitor {
            instance?.let { return it }
            synchronized(this) {
                instance?.let { return it }
                val logger = SecureLogger.get() ?: SecureLogger.init(context)
                val m = IntegrityMonitor(context.applicationContext, logger)
                m.start()
                instance = m
                return m
            }
        }

        fun get(): IntegrityMonitor? = instance
    }

    private val scheduler: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "dash-integrity-monitor").apply { isDaemon = true }
        }
    private val running = AtomicBoolean(false)
    @Volatile private var healthy = true
    // Per-tick failure counter — incremented by flagTamper, reset at the
    // start of every runCheckSafely. A tick that finishes with 0 counts
    // AND was previously unhealthy flips `healthy` back to true, so
    // recoverable transients (missing DEX at early boot, etc.) don't
    // brick the dispatcher for the whole session.
    @Volatile private var thisCheckFailures: Int = 0
    private val mtimeCache = mutableMapOf<String, Long>()
    private var expectedShas: Map<String, String> = emptyMap()

    fun isHealthy(): Boolean = healthy

    fun start() {
        if (!running.compareAndSet(false, true)) return
        expectedShas = readManifestOrEmpty()
        if (expectedShas.isEmpty()) {
            Log.i(TAG, "no manifest — integrity checks limited to process probes")
        }
        // SignaturePin is checked once at start. Repackaged-and-resigned
        // APKs would fail this — see SignaturePin.kt. Non-blocking: if the
        // pin can't be verified for any reason (no baseline, PM error),
        // we don't refuse to start; we just don't get the bonus signal.
        verifySignerOnce()
        // initialDelay=5s so the first check fires shortly after boot once
        // staging has had time to finish, instead of waiting the full
        // 60s period. Subsequent checks run every CHECK_PERIOD_SEC.
        scheduler.scheduleWithFixedDelay(
            { runCheckSafely() },
            5L,
            CHECK_PERIOD_SEC,
            TimeUnit.SECONDS,
        )
    }

    private fun verifySignerOnce() {
        when (val r = SignaturePin.verify(context, BuildConfig.EXPECTED_SIGNER_SHA)) {
            is SignaturePin.Result.Match -> {
                Log.i(TAG, "signer pin OK")
            }
            is SignaturePin.Result.Mismatch -> {
                // Repackaged APK detected. Fail closed: flag tamper, log
                // the actual SHA for local diagnostic comparison. Do not
                // throw — that would just give the attacker a stack trace
                // hint about what tripped the check.
                flagTamper("signer_pin_mismatch", "<baseline>", r.actualSha)
            }
            is SignaturePin.Result.NoBaseline -> {
                // Dev build / no baseline configured — explicit log so
                // production CI can spot if EXPECTED_SIGNER_SHA wasn't
                // injected.
                Log.w(TAG, "signer pin: no baseline (dev build?)")
            }
            is SignaturePin.Result.Unavailable -> {
                Log.w(TAG, "signer pin unavailable: ${r.reason}")
            }
        }
    }

    private fun runCheckSafely() {
        try {
            // Track if THIS tick found any tamper. If nothing fired + we
            // were previously unhealthy (e.g. transient staging issue at
            // boot that's since been resolved), flip back to healthy so
            // the router resumes dispatches. Without this, any single
            // tamper flag is terminal — including recoverable conditions
            // like "DEX file wasn't staged yet at first check".
            val tamperedBefore = !healthy
            thisCheckFailures = 0
            checkDexes()
            checkTamperProbes()
            if (tamperedBefore && thisCheckFailures == 0) {
                Log.i(TAG, "integrity recovered — previous tamper flags no longer seen")
                healthy = true
            }
        } catch (t: Throwable) {
            Log.w(TAG, "check failed: ${t.message}")
        }
    }

    private fun checkDexes() {
        for ((name, expectedHex) in expectedShas) {
            val file = File(STAGE_DIR, name)
            if (!file.exists()) {
                flagTamper("missing_dex:$name", expectedHex, "<none>")
                continue
            }
            val mtime = file.lastModified()
            val cached = mtimeCache[name]
            if (cached != null && cached == mtime) continue
            mtimeCache[name] = mtime
            val actualHex = hex(CryptoUtils.sha256(file.readBytes()))
            if (actualHex != expectedHex) {
                flagTamper("dex:$name", expectedHex, actualHex)
            }
        }
    }

    /**
     * Score the five independent tamper probes. A single probe firing is
     * ignored — each can be bypassed with one line of Frida script — but
     * two or more independent signals firing is the live-instrumentation
     * threshold.
     */
    private fun checkTamperProbes() {
        val result = TamperProbes.score()
        if (result.firedCount >= TAMPER_THRESHOLD) {
            flagTamper(
                "tamper_multi:${result.firedNames().joinToString(",")}",
                "< $TAMPER_THRESHOLD",
                result.firedCount.toString(),
            )
        }
    }

    private fun flagTamper(subject: String, expected: String, actual: String) {
        // On an emulator OR any debug build the app is debug-keystore signed
        // and runs without staged unit DEX, so SignaturePin + the DEX sweep
        // ALWAYS "tamper". Log but don't flip the daemon unhealthy (which would
        // pause car commands). Debug/emulator exemptions are unchanged;
        // release builds still enforce integrity and write local diagnostics.
        if (DeviceEnv.isEmulator || BuildConfig.DEBUG) {
            Log.i(TAG, "integrity signal (dev build, not reported): $subject")
            return
        }
        thisCheckFailures++
        if (healthy) {
            Log.e(TAG, "integrity tamper: $subject (expected=$expected actual=$actual)")
            healthy = false
        }
        logger?.emitIntegrity(subject, expected, actual)
    }

    private fun readManifestOrEmpty(): Map<String, String> {
        return try {
            val raw = context.assets.open(MANIFEST_ASSET).use {
                it.readBytes().toString(Charsets.UTF_8)
            }
            val units = JSONObject(raw).getJSONArray("units")
            buildMap {
                for (i in 0 until units.length()) {
                    val u = units.getJSONObject(i)
                    put(u.getString("name"), u.getString("sha256"))
                }
            }
        } catch (_: Throwable) {
            emptyMap()
        }
    }

    private fun hex(bytes: ByteArray): String {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) sb.append(String.format("%02x", b))
        return sb.toString()
    }
}

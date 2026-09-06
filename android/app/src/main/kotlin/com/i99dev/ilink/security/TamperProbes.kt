package com.i99dev.ilink.security

import java.io.File

/**
 * Multi-signal instrumentation detection. Each probe is cheap, independent,
 * and returns `true` when it sees something that suggests Frida / Xposed /
 * ptrace attach. [score] runs all probes and returns how many fired — the
 * monitor raises a tamper flag when `score >= 2`, because any single probe
 * is a one-line bypass for an attentive attacker. Two independent signals
 * firing is much harder to quietly mask.
 *
 * This is the Kotlin baseline. When the NDK module lands (plan Phase 3
 * infra), these probes move into `secrets.so` — native-side is harder to
 * hook than Java-side reflection targets. The public [score] / [Result]
 * surface stays identical so [IntegrityMonitor] doesn't change.
 */
object TamperProbes {
    data class Result(
        val tracerPid: Boolean,
        val mapsScan: Boolean,
        val portsScan: Boolean,
        val threadsScan: Boolean,
        val timingCanary: Boolean,
        val tracedAtLoad: Boolean,
    ) {
        /** Count of probes that fired. Threshold for raising tamper: ≥ 2. */
        val firedCount: Int =
            (if (tracerPid) 1 else 0) +
            (if (mapsScan) 1 else 0) +
            (if (portsScan) 1 else 0) +
            (if (threadsScan) 1 else 0) +
            (if (timingCanary) 1 else 0) +
            (if (tracedAtLoad) 1 else 0)

        /** Names of probes that fired, for logging. */
        fun firedNames(): List<String> = buildList {
            if (tracerPid) add("tracer_pid")
            if (mapsScan) add("maps_scan")
            if (portsScan) add("ports_scan")
            if (threadsScan) add("threads_scan")
            if (timingCanary) add("timing_canary")
            if (tracedAtLoad) add("traced_at_load")
        }
    }

    /** Run every probe. Each failure is caught locally so one broken probe
     *  doesn't mask the others. */
    fun score(): Result = Result(
        tracerPid = safely(::probeTracerPid),
        mapsScan = safely(::probeMapsScan),
        portsScan = safely(::probePortsScan),
        threadsScan = safely(::probeThreadsScan),
        timingCanary = safely(::probeTimingCanary),
        // tracedAtLoad is captured ONCE at JNI_OnLoad and cached — strongest
        // anti-debug signal we have. Native-only: returns false if the .so
        // didn't load (e.g. debug builds without NDK).
        tracedAtLoad = NativeSecrets.tracedAtLoad() ?: false,
    )

    private fun safely(block: () -> Boolean): Boolean = try {
        block()
    } catch (_: Throwable) {
        false
    }

    // --- Probe 1: TracerPid ------------------------------------------------

    /** Non-zero TracerPid = a debugger / ptrace attach is live. Prefers
     *  the native probe when [NativeSecrets] is loaded — the native
     *  version is harder to bypass from a Java-only Frida script. Falls
     *  back to a pure-JVM read of /proc/self/status otherwise. */
    fun probeTracerPid(): Boolean {
        val nativeVal = NativeSecrets.tracerPid()
        if (nativeVal != null) {
            return nativeVal > 0
        }
        val pid = File("/proc/self/status").useLines { lines ->
            for (l in lines) {
                if (l.startsWith("TracerPid:")) {
                    return@useLines l.substringAfter(":").trim().toIntOrNull()
                }
            }
            null
        }
        return pid != null && pid != 0
    }

    // --- Probe 2: /proc/self/maps scan ------------------------------------

    /** Frida loads its agent library + V8 runtime into the process map; the
     *  names below are stable across Frida versions. */
    private val MAPS_NEEDLES = listOf(
        "frida-agent",
        "frida-gum",
        "gum-js-loop",
        "linjector",
    )

    fun probeMapsScan(): Boolean {
        // Prefer native — the C-side reads /proc/self/maps without
        // crossing the JVM, raising the bar for a Java-only Frida
        // bypass. Kotlin fallback runs when the .so didn't load.
        val nativeVal = NativeSecrets.hasFridaInMaps()
        if (nativeVal != null) return nativeVal

        val maps = File("/proc/self/maps")
        if (!maps.exists()) return false
        return maps.useLines { lines ->
            for (l in lines) {
                for (n in MAPS_NEEDLES) {
                    if (l.contains(n)) return@useLines true
                }
            }
            false
        }
    }

    // --- Probe 3: /proc/net/tcp port scan ---------------------------------

    /** Frida listens on 27042-27052 (default CLI range). Each /proc/net/tcp
     *  row has a hex-encoded local address `ip:port` in column 2. */
    private const val FRIDA_PORT_MIN = 27042
    private const val FRIDA_PORT_MAX = 27052
    private val TCP_FILES = listOf("/proc/net/tcp", "/proc/net/tcp6")

    fun probePortsScan(): Boolean {
        for (path in TCP_FILES) {
            val f = File(path)
            if (!f.exists()) continue
            val hit = f.useLines { lines ->
                // Skip header row.
                for (l in lines.drop(1)) {
                    val cols = l.trim().split(Regex("\\s+"))
                    if (cols.size < 4) continue
                    val local = cols[1]
                    val colon = local.lastIndexOf(':')
                    if (colon < 0) continue
                    val portHex = local.substring(colon + 1)
                    val port = portHex.toIntOrNull(16) ?: continue
                    if (port in FRIDA_PORT_MIN..FRIDA_PORT_MAX) {
                        return@useLines true
                    }
                }
                false
            }
            if (hit) return true
        }
        return false
    }

    // --- Probe 4: thread names --------------------------------------------

    /** Frida spawns worker threads with distinctive names. They show up in
     *  `/proc/self/task/<tid>/status` as `Name:` lines. */
    private val THREAD_NEEDLES = setOf("gmain", "gdbus", "pool-frida", "gum-js-loop")

    fun probeThreadsScan(): Boolean {
        val taskDir = File("/proc/self/task")
        val children = taskDir.listFiles() ?: return false
        for (tid in children) {
            val statusFile = File(tid, "status")
            if (!statusFile.exists()) continue
            val name = try {
                statusFile.useLines { lines ->
                    for (l in lines) {
                        if (l.startsWith("Name:")) {
                            return@useLines l.substringAfter(":").trim()
                        }
                    }
                    null
                }
            } catch (_: Throwable) {
                null
            }
            if (name != null && THREAD_NEEDLES.contains(name)) return true
        }
        return false
    }

    // --- Probe 5: timing canary -------------------------------------------

    /**
     * Run a deterministic CPU-bound op and compare nanoTime deltas. Frida
     * instruments syscalls and hot Java methods — the instrumented path
     * runs measurably slower. Threshold calibrated against a cold-start
     * baseline on the target HU.
     *
     * Note: this is the Kotlin baseline. Native-side (NDK) the canary uses
     * a known-cycle-count loop and the overhead signal is much cleaner.
     * Kotlin JIT noise makes this probe softer — that's why we require
     * ≥2 probes instead of acting on this one alone.
     */
    private const val CANARY_ITERATIONS = 50_000
    private const val CANARY_SLOW_NS = 15_000_000L // 15ms — calibrate on HU

    fun probeTimingCanary(): Boolean {
        val start = System.nanoTime()
        var acc = 1L
        for (i in 1..CANARY_ITERATIONS) {
            // Integer-only op; no allocations, no syscalls — steady baseline.
            acc = (acc * 31 + i) and 0xFFFFFFFFL
        }
        val elapsed = System.nanoTime() - start
        // `acc` is intentionally "used" via this throwaway check so the JIT
        // can't dead-code the loop. Frida hooks tend to inflate by 10x+; the
        // CANARY_SLOW_NS threshold is deliberately loose.
        if (acc == 0L) return true
        return elapsed > CANARY_SLOW_NS
    }
}

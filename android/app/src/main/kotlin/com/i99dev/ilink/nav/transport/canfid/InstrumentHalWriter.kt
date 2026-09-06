package com.i99dev.ilink.nav.transport.canfid

import android.content.Context

/**
 * The privileged side of CAN-FID: a [FidWriter] that drives the BYD instrument
 * cluster directly through the vendor HAL, all by reflection (the HAL classes
 * are only on the system classpath, reachable from a shell-uid `app_process`,
 * not from the app's untrusted_app process).
 *
 * Mechanism is byte-faithful to the reference's `CarControlImpl`:
 *   ctx  = ActivityThread.systemMain().getSystemContext().createPackageContext(pkg, INCLUDE_CODE|IGNORE_SECURITY)
 *   dev  = android.hardware.bydauto.instrument.BYDAutoInstrumentDevice.getInstance(ctx)
 *   ev   = new android.hardware.bydauto.BYDAutoEventValue(); ev.intValue = v   (or ev.bufferDataValue = bytes)
 *   rc   = dev.set(new int[]{featureId}, ev)
 *
 * This is what the **7.0UI (Leopard 7)** cluster actually reads — its AMap
 * service writes the same `INSTRUMENT_GUIDE_INFO_*` feature ids and
 * `com.byd.cluster` consumes them (the SOME/IP HudNaviInfoService is dead on
 * that ROM). [BydGuidance] supplies the proven send-sequences on top of this.
 *
 * Run standalone (M0 spike) via:
 *   CLASSPATH=<our.apk> app_process /system/bin \
 *     com.i99dev.ilink.nav.transport.canfid.InstrumentHalWriterKt [iconCode] [distM] [road]
 */
class InstrumentHalWriter(ctx: Context) : FidWriter {

    private val instrument: Any? = runCatching {
        val cls = Class.forName("android.hardware.bydauto.instrument.BYDAutoInstrumentDevice")
        cls.getMethod("getInstance", Context::class.java).invoke(null, ctx)
    }.getOrNull()

    private val setting: Any? = runCatching {
        val cls = Class.forName("android.hardware.bydauto.setting.BYDAutoSettingDevice")
        cls.getMethod("getInstance", Context::class.java).invoke(null, ctx)
    }.getOrNull()

    private val eventValueCls: Class<*> = Class.forName("android.hardware.bydauto.BYDAutoEventValue")

    /** The 7.0UI HUD wake handshake (verified, cached). One per writer = one per
     *  daemon lifetime, so the awake state persists across frames. */
    private val hudWake = BydHudWake()

    override fun ready(): Boolean = instrument != null

    /** Diagnostics: has the 7.0UI HUD been verified awake this session? */
    fun hudAwake(): Boolean = hudWake.isAwake

    private fun eventValue(field: String, set: (Any) -> Unit): Any {
        val ev = eventValueCls.getDeclaredConstructor().newInstance()
        set(ev)
        return ev
    }

    /** dev.set(int[]{fid}, BYDAutoEventValue{intValue=value}) → result code.
     *  Falls back to the raw `service call` SHELL form when the reflected HAL is
     *  null (so guidance still reaches the cluster on those firmwares). */
    override fun instrumentInt(fid: Int, value: Int) {
        val dev = instrument
        if (dev == null) {
            instrumentIntShell(fid, value, BydFid.SHELL_OP_INSTRUMENT)
            return
        }
        val ev = eventValueCls.getDeclaredConstructor().newInstance()
        eventValueCls.getField("intValue").setInt(ev, value)
        dev.javaClass.getMethod("set", IntArray::class.java, eventValueCls)
            .invoke(dev, intArrayOf(fid), ev)
    }

    /** Raw SHELL set: `service call autoservice 6 i32 <op> i32 <fid> i32 <value>`
     *  (op = device selector, value last). Runs as the daemon's shell uid. */
    override fun instrumentIntShell(fid: Int, value: Int, op: Int): Boolean = runCatching {
        runShell("service call autoservice 6 i32 $op i32 $fid i32 $value") != null
    }.getOrDefault(false)

    override fun instrumentBytes(fid: Int, value: ByteArray) {
        val dev = instrument ?: return
        val ev = eventValueCls.getDeclaredConstructor().newInstance()
        eventValueCls.getField("bufferDataValue").set(ev, value)
        dev.javaClass.getMethod("set", IntArray::class.java, eventValueCls)
            .invoke(dev, intArrayOf(fid), ev)
    }

    override fun settingInt(fid: Int, value: Int) {
        val dev = setting
        if (dev == null) {
            instrumentIntShell(fid, value, BydFid.SHELL_OP_SETTING)
            return
        }
        val ev = eventValueCls.getDeclaredConstructor().newInstance()
        eventValueCls.getField("intValue").setInt(ev, value)
        dev.javaClass.getMethod("set", IntArray::class.java, eventValueCls)
            .invoke(dev, intArrayOf(fid), ev)
    }

    override fun instrumentRead(fid: Int): Int {
        instrument?.let { dev ->
            runCatching {
                val ev = dev.javaClass.getMethod("get", Int::class.javaPrimitiveType).invoke(dev, fid)
                eventValueCls.getField("intValue").getInt(ev)
            }.getOrNull()?.let { return it }
        }
        // SHELL get fallback (the wake verify path): parse the `service call` Parcel.
        return readShell(fid, BydFid.SHELL_OP_INSTRUMENT) ?: 0
    }

    /** Run a command as the daemon's (shell) uid; stdout or null on failure. */
    private fun runShell(cmd: String): String? = runCatching {
        val p = Runtime.getRuntime().exec(arrayOf("sh", "-c", cmd))
        val out = p.inputStream.bufferedReader().use { it.readText() }
        p.waitFor()
        out
    }.getOrNull()

    /** `service call autoservice 5 i32 <op> i32 <fid>` → the returned int. The
     *  reply looks like `Result: Parcel(00000000 00000002  '........')` —
     *  word0 = status, word1 = the value. */
    private fun readShell(fid: Int, op: Int): Int? = runCatching {
        val out = runShell("service call autoservice 5 i32 $op i32 $fid") ?: return null
        PARCEL_WORDS.find(out)?.groupValues?.get(2)?.toLong(16)?.toInt()
    }.getOrNull()

    override fun cameraGuidance(type: Int, distanceMeters: Int, state: Int) {
        val dev = instrument ?: return
        runCatching {
            dev.javaClass.getMethod(
                "sendCameraGuidanceInfo",
                Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType,
            ).invoke(dev, type, distanceMeters, state)
        }
    }

    override fun safeGuidance(type: Int, distanceMeters: Int, state: Int) {
        val dev = instrument ?: return
        runCatching {
            dev.javaClass.getMethod(
                "sendSafeGuidanceInfo",
                Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType,
            ).invoke(dev, type, distanceMeters, state)
        }
    }

    /** One full guidance frame (HUD wake + maneuver + distance + road), or
     *  navi-off. The single entry the persistent daemon + the spike both call,
     *  so the [BydGuidance] send-sequence lives in one place.
     *
     *  @return true if the writer is driving the cluster (typed HAL present, or
     *  the wake has verified the SHELL path) — what the daemon reports as `ok`. */
    fun writeFrame(
        icon: Int,
        dist: Int,
        road: String,
        remTimeSec: Int,
        remDistMeters: Int,
        on: Boolean,
        cameraType: Int = -1,
        cameraDist: Int = -1,
        cameraState: Int = -1,
        safetyType: Int = -1,
        safetyDist: Int = -1,
        safetyState: Int = -1,
    ): Boolean {
        if (on) {
            // Wake the 7.0UI HUD first — without it the cluster ignores the
            // guidance writes below (the L7 "write ok but native nav still shows").
            hudWake.ensure(this)
            BydGuidance.sendSimpleGuidanceInfo(this, icon, dist)
            // Always write the road — an empty string clears a stale street under
            // a new maneuver (the previous non-blank→blank transition stuck).
            BydGuidance.sendNextPathName(this, road)
            // ETA on the cluster — only when both remaining time + distance known.
            if (remTimeSec >= 0 && remDistMeters >= 0) {
                BydGuidance.sendTripInfo(this, remTimeSec, remDistMeters)
            }
            // Camera / safety alerts (Yandex; P3) — distance/state default to the
            // the reference-verified 100/2 when the producer didn't specify.
            if (cameraType >= 0) {
                cameraGuidance(cameraType, cameraDist.takeIf { it >= 0 } ?: 100, cameraState.takeIf { it >= 0 } ?: 2)
            }
            if (safetyType >= 0) {
                safeGuidance(safetyType, safetyDist.takeIf { it >= 0 } ?: 100, safetyState.takeIf { it >= 0 } ?: 2)
            }
        } else {
            hudWake.reset()
            BydGuidance.turnOffNavi(this)
        }
        return ready() || hudWake.isAwake
    }

    private companion object {
        /** First two 32-bit words of a `service call` Parcel reply (status, value). */
        val PARCEL_WORDS = Regex("""Parcel\(([0-9a-fA-F]{8})\s+([0-9a-fA-F]{8})""")
    }
}

/** Get a HAL-capable system Context from a shell `app_process` (the reference's path).
 *  This 7.0UI ROM's `systemMain()` creates an ActivityThread Handler WITHOUT
 *  preparing the looper itself, so we must prepare the main looper first. */
fun navHalSystemContext(pkg: String = "com.i99dev.ilink"): Context {
    if (android.os.Looper.myLooper() == null) android.os.Looper.prepareMainLooper()
    val at = Class.forName("android.app.ActivityThread")
    val thread = at.getMethod("systemMain").invoke(null)
    val sys = at.getMethod("getSystemContext").invoke(thread) as Context
    // CONTEXT_INCLUDE_CODE | CONTEXT_IGNORE_SECURITY = 1 | 2 = 3
    return runCatching { sys.createPackageContext(pkg, 3) }.getOrDefault(sys)
}

/**
 * M0 spike — run as shell `app_process` on a 7.0UI car to prove the instrument
 * HAL accepts a guidance write (does the cluster render a turn?). Prints a
 * step-by-step go/no-go report; the human confirms the physical cluster.
 */
fun main(args: Array<String>) {
    val icon = args.getOrNull(0)?.toIntOrNull() ?: 4 // turn-left-ish
    val dist = args.getOrNull(1)?.toIntOrNull() ?: 300
    val road = args.getOrNull(2) ?: "Test Rd"
    val off = args.getOrNull(3) == "off"
    println("I99_HAL_SPIKE start icon=$icon dist=$dist road=$road off=$off")
    try {
        if (android.os.Looper.myLooper() == null) android.os.Looper.prepareMainLooper()
        val at = Class.forName("android.app.ActivityThread")
        val thread = at.getMethod("systemMain").invoke(null)
        println("I99_HAL_SPIKE systemMain=${thread != null}")
        val sys = at.getMethod("getSystemContext").invoke(thread)
        println("I99_HAL_SPIKE getSystemContext=${sys != null}")
        val ctx = runCatching { (sys as Context).createPackageContext("com.i99dev.ilink", 3) }
            .getOrDefault(sys as Context)
        println("I99_HAL_SPIKE ctx=${ctx != null}")
        val w = InstrumentHalWriter(ctx)
        println("I99_HAL_SPIKE instrument.ready=${w.ready()}")
        if (!w.ready()) {
            println("I99_HAL_SPIKE FAIL: BYDAutoInstrumentDevice null (HAL not reachable as shell)"); return
        }
        w.writeFrame(icon, dist, road, remTimeSec = -1, remDistMeters = -1, on = !off)
        println(
            if (off) "I99_HAL_SPIKE OK: navi off"
            else "I99_HAL_SPIKE OK: wrote naviOn + icon $icon @ ${dist}m + '$road' — check the cluster",
        )
    } catch (t: Throwable) {
        println("I99_HAL_SPIKE FAIL ${t.javaClass.name}: ${t.message}")
        t.printStackTrace()
    }
    // systemMain() attaches non-daemon binder/ActivityThread threads that keep
    // the VM alive after main() returns — force-exit so the per-frame caller
    // doesn't block on a leftover process.
    System.out.flush()
    Runtime.getRuntime().halt(0)
}

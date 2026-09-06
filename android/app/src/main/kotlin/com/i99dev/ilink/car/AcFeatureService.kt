package com.i99dev.ilink.car

import android.content.Context
import android.os.IBinder
import android.os.Parcel
import android.util.Log

/**
 * Wraps byd_airconditioning. Ported from testing_case/java_src/AcControl.java.
 *
 * Layout:
 *   main binder "byd_airconditioning" (IBydAcService)
 *     ├─ TX 3 getService(name) → sub-binder  (fragrance / ac / setting / seat / airclean)
 *     ├─ TX 4 isFeature(name) → bool
 *     ├─ TX 1,2,5 no-arg ints (carModeId, deviceType, seatDistStyle)
 *   sub services use their own AIDL descriptors + Parcel layout.
 */
class AcFeatureService(private val context: Context) {
    companion object {
        private const val TAG = "AcFeatureService"

        const val BYDAC = "com.byd.ac.IBydAcService"
        const val SEAT = "com.byd.ac.IAcSeatVentilationHeating"
        const val FRAG = "com.byd.ac.IAcFragrance"
        const val CLEAN = "com.byd.ac.IAcAirClean"
        const val SETT = "com.byd.ac.IAcSetting"
        const val ACAC = "com.byd.ac.IAcAirConditioner"

        const val SVC_SEAT = "AC_SEAT_VENTILATION_HEATING_SERVICE"
        const val SVC_AC = "AC_AIRCONDITIONER_SERVICE"
        const val SVC_FRAG = "AC_FRAGRANCE_SERVICE"
        const val SVC_CLEAN = "AC_AIR_CLEAN_SERVICE"
        const val SVC_SETT = "AC_SETTING_SERVICE"
    }

    @Volatile private var main: IBinder? = null

    private fun ensureMain(): IBinder {
        main?.let { return it }
        synchronized(this) {
            main?.let { return it }
            val sm = Class.forName("android.os.ServiceManager")
            val b = sm.getMethod("getService", String::class.java)
                .invoke(null, "byd_airconditioning") as? IBinder
                ?: throw IllegalStateException("byd_airconditioning not registered")
            main = b
            return b
        }
    }

    private fun getSub(name: String): IBinder? {
        val m = ensureMain()
        val d = Parcel.obtain(); val r = Parcel.obtain()
        return try {
            d.writeInterfaceToken(BYDAC); d.writeString(name)
            m.transact(3, d, r, 0); r.readException()
            r.readStrongBinder()
        } catch (e: Throwable) {
            Log.w(TAG, "getSub($name): ${e.message}")
            null
        } finally { r.recycle(); d.recycle() }
    }

    // ---- Dispatcher entrypoint used by the MethodChannel ----

    fun transact(service: String, method: String, args: Map<String, Any?>): Map<String, Any?> {
        return try {
            when (service) {
                "frag" -> fragDispatch(method, args)
                "ac" -> acDispatch(method, args)
                "setting" -> settingDispatch(method, args)
                "seat" -> seatDispatch(method, args)
                "services" -> servicesSnapshot()
                else -> mapOf("error" to "unknown service: $service")
            }
        } catch (e: Throwable) {
            Log.e(TAG, "transact($service/$method) ${e.message}", e)
            mapOf("error" to (e.message ?: e.javaClass.simpleName))
        }
    }

    // ===== FRAGRANCE =====
    private fun fragDispatch(method: String, args: Map<String, Any?>): Map<String, Any?> {
        val fb = getSub(SVC_FRAG) ?: return mapOf("error" to "fragrance service null")
        return when (method) {
            "status" -> fragStatus(fb)
            "on" -> {
                val level = (args["level"] as? Int)?.coerceIn(1, 3) ?: 2
                fragSetData(fb, 210, -1, level)
                mapOf("ok" to true, "level" to level)
            }
            "off" -> { fragSetData(fb, 210, -1, 4); mapOf("ok" to true) }
            "select" -> {
                val slot = (args["slot"] as? Int) ?: return mapOf("error" to "slot required")
                fragSetData(fb, 211, -1, slot)
                mapOf("ok" to true, "slot" to slot)
            }
            else -> mapOf("error" to "unknown frag method: $method")
        }
    }

    private fun fragStatus(fb: IBinder): Map<String, Any?> {
        val out = linkedMapOf<String, Any?>()
        out["online"] = noArgInt(fb, FRAG, 4)
        out["surplus"] = getIntArray(fb, FRAG, 5)?.toList()
        out["autoStudy"] = noArgInt(fb, FRAG, 6)
        val slots = mutableListOf<Map<String, Any?>>()
        for (slot in 1..3) {
            val sw = fragGetData(fb, 2, slot)
            slots += mapOf(
                "slot" to slot,
                "installed" to fragGetData(fb, 1, slot),
                "switch" to sw,
                "switchName" to when (sw) {
                    1 -> "LIGHT"; 2 -> "MIDDLE"; 3 -> "DENSE"; 4 -> "OFF"; else -> "?"
                },
                "type" to fragGetData(fb, 4, slot),
            )
        }
        out["slots"] = slots
        out["currentSlot"] = fragGetData(fb, 3, 0)
        return out
    }

    // ===== AC (IAcAirConditioner) =====
    private fun acDispatch(method: String, args: Map<String, Any?>): Map<String, Any?> {
        val ab = getSub(SVC_AC) ?: return mapOf("error" to "AC service null")
        return when (method) {
            "status" -> acStatus(ab)
            "set" -> {
                val id = (args["id"] as? Int) ?: return mapOf("error" to "id required")
                val area = (args["area"] as? Int) ?: 256
                val value = (args["value"] as? Int) ?: return mapOf("error" to "value required")
                writePropValue(ab, ACAC, 3, id, area, value)
                mapOf("ok" to true, "id" to id, "area" to area, "value" to value)
            }
            "get" -> {
                val id = (args["id"] as? Int) ?: return mapOf("error" to "id required")
                val area = (args["area"] as? Int) ?: 256
                val v = readPropValue(ab, ACAC, 2, id, area)
                mapOf("id" to id, "area" to area, "value" to v)
            }
            else -> mapOf("error" to "unknown ac method: $method")
        }
    }

    private fun acStatus(ab: IBinder): Map<String, Any?> {
        val out = linkedMapOf<String, Any?>()
        out["isAcOnline"] = safeNoArg(ab, ACAC, 25)
        out["isRearAcOnline"] = safeNoArg(ab, ACAC, 26)
        out["acType"] = safeNoArg(ab, ACAC, 28)
        out["frontConfig"] = safeNoArg(ab, ACAC, 29)
        out["areaType"] = safeNoArg(ab, ACAC, 4)
        out["tempUnitType"] = safeNoArg(ab, ACAC, 6)
        out["isEV"] = safeNoArg(ab, ACAC, 20)
        out["isHEV"] = safeNoArg(ab, ACAC, 21)
        out["minWindLevel"] = safeNoArg(ab, ACAC, 15)
        out["anionStatus"] = safeNoArg(ab, ACAC, 10)
        val props = linkedMapOf<Int, Any?>()
        for (pid in intArrayOf(101, 102, 103, 104, 105, 107, 108, 109, 110, 113, 114, 115, 130, 135)) {
            props[pid] = readPropValue(ab, ACAC, 2, pid, 256)
        }
        out["properties"] = props.mapKeys { it.key.toString() }
        return out
    }

    // ===== SETTING =====
    private fun settingDispatch(method: String, args: Map<String, Any?>): Map<String, Any?> {
        val sb = getSub(SVC_SETT) ?: return mapOf("error" to "setting service null")
        return when (method) {
            "status" -> {
                val names = arrayOf(
                    "", "autoMode", "heatMode", "remoteTime", "autoClean",
                    "parkingAutoLoop", "tunnelAutoLoop", "btReduceWind", "intellPartition",
                    "intellControlAid", "autoModeStudy", "heatModeStudy", "airAutoLoop",
                    "fragranceTime", "fragTimeStudy", "compensateVent", "compensateStudy"
                )
                val out = linkedMapOf<String, Any?>()
                for (id in 401..416) {
                    val idx = id - 400
                    val label = if (idx < names.size) names[idx] else "unknown_$id"
                    out[label] = safeArgInt(sb, SETT, 4, id)
                }
                out
            }
            "set" -> {
                val id = (args["id"] as? Int) ?: return mapOf("error" to "id required")
                val value = (args["value"] as? Int) ?: return mapOf("error" to "value required")
                writePropValue(sb, SETT, 3, id, -1, value)
                mapOf("ok" to true, "id" to id, "value" to value)
            }
            else -> mapOf("error" to "unknown setting method: $method")
        }
    }

    // ===== SEAT (often null on Leopard 8) =====
    private fun seatDispatch(method: String, args: Map<String, Any?>): Map<String, Any?> {
        val sb = getSub(SVC_SEAT)
            ?: return mapOf("error" to "AC_SEAT_VENTILATION_HEATING_SERVICE is null on this car")
        return when (method) {
            "status" -> {
                val out = linkedMapOf<String, Any?>()
                out["isPowerOn"] = noArgBool(sb, SEAT, 6)
                val seats = mutableListOf<Map<String, Any?>>()
                for (sid in 1..4) {
                    seats += mapOf(
                        "id" to sid,
                        "ventStatus" to safeArgInt(sb, SEAT, 2, sid),
                        "heatStatus" to safeArgInt(sb, SEAT, 3, sid),
                        "ventLevel" to safeArgInt(sb, SEAT, 4, sid),
                        "heatLevel" to safeArgInt(sb, SEAT, 5, sid),
                    )
                }
                out["seats"] = seats
                out
            }
            "set" -> {
                val sid = (args["sid"] as? Int) ?: return mapOf("error" to "sid required")
                val type = (args["type"] as? Int) ?: return mapOf("error" to "type required")
                val level = (args["level"] as? Int) ?: return mapOf("error" to "level required")
                val d = Parcel.obtain(); val r = Parcel.obtain()
                try {
                    d.writeInterfaceToken(SEAT)
                    d.writeInt(sid); d.writeInt(type); d.writeInt(level)
                    sb.transact(7, d, r, 0); r.readException()
                } finally { r.recycle(); d.recycle() }
                mapOf("ok" to true, "sid" to sid, "type" to type, "level" to level)
            }
            else -> mapOf("error" to "unknown seat method: $method")
        }
    }

    private fun servicesSnapshot(): Map<String, Any?> {
        val m = ensureMain()
        val out = linkedMapOf<String, Any?>()
        out["carModeId"] = noArgInt(m, BYDAC, 1)
        out["deviceType"] = noArgInt(m, BYDAC, 2)
        out["seatDistStyle"] = noArgInt(m, BYDAC, 5)
        val services = linkedMapOf<String, Any?>()
        for (s in listOf(SVC_SEAT, SVC_AC, SVC_FRAG, SVC_CLEAN, SVC_SETT)) {
            services[s] = getSub(s) != null
        }
        out["services"] = services
        val features = linkedMapOf<String, Any?>()
        for (f in listOf(
            "AC_AIRCLEAN_FEATURE", "AC_FRAGRANCE_FEATURE",
            "AC_HAS_RSE_FEATURE", "AC_REAR_ELECTRIC_FEATURE"
        )) {
            features[f] = isFeature(m, f)
        }
        out["features"] = features
        return out
    }

    // ---- Low-level Parcel helpers ----

    private fun fragGetData(fb: IBinder, type: Int, slot: Int): Int {
        val d = Parcel.obtain(); val r = Parcel.obtain()
        return try {
            d.writeInterfaceToken(FRAG); d.writeInt(type); d.writeInt(slot)
            fb.transact(2, d, r, 0); r.readException(); r.readInt()
        } finally { r.recycle(); d.recycle() }
    }

    private fun fragSetData(fb: IBinder, id: Int, area: Int, value: Int) {
        val d = Parcel.obtain(); val r = Parcel.obtain()
        try {
            d.writeInterfaceToken(FRAG)
            d.writeInt(1) // non-null flag for typed object
            d.writeInt(id); d.writeInt(area)
            d.writeString("java.lang.Integer")
            d.writeValue(Integer.valueOf(value))
            fb.transact(3, d, r, 0); r.readException()
        } finally { r.recycle(); d.recycle() }
    }

    private fun writePropValue(
        binder: IBinder, desc: String, txn: Int, id: Int, area: Int, value: Int,
    ) {
        val d = Parcel.obtain(); val r = Parcel.obtain()
        try {
            d.writeInterfaceToken(desc)
            d.writeInt(1)
            d.writeInt(id); d.writeInt(area)
            d.writeString("java.lang.Integer")
            d.writeValue(Integer.valueOf(value))
            binder.transact(txn, d, r, 0); r.readException()
        } finally { r.recycle(); d.recycle() }
    }

    private fun readPropValue(
        binder: IBinder, desc: String, txn: Int, id: Int, area: Int,
    ): Any? {
        val d = Parcel.obtain(); val r = Parcel.obtain()
        return try {
            d.writeInterfaceToken(desc)
            d.writeInt(id); d.writeInt(area)
            binder.transact(txn, d, r, 0); r.readException()
            val flag = r.readInt()
            if (flag == 0) return null
            /* rId */ r.readInt()
            /* rArea */ r.readInt()
            /* className */ r.readString()
            r.readValue(javaClass.classLoader)
        } catch (e: Throwable) {
            "ERR: ${e.message}"
        } finally { r.recycle(); d.recycle() }
    }

    private fun noArgInt(b: IBinder, desc: String, txn: Int): Int {
        val d = Parcel.obtain(); val r = Parcel.obtain()
        return try {
            d.writeInterfaceToken(desc); b.transact(txn, d, r, 0); r.readException(); r.readInt()
        } finally { r.recycle(); d.recycle() }
    }

    private fun safeNoArg(b: IBinder, desc: String, txn: Int): Any? = try {
        noArgInt(b, desc, txn)
    } catch (e: Throwable) { "ERR: ${e.message}" }

    private fun safeArgInt(b: IBinder, desc: String, txn: Int, arg: Int): Any? {
        val d = Parcel.obtain(); val r = Parcel.obtain()
        return try {
            d.writeInterfaceToken(desc); d.writeInt(arg)
            b.transact(txn, d, r, 0); r.readException(); r.readInt()
        } catch (e: Throwable) {
            "ERR: ${e.message}"
        } finally { r.recycle(); d.recycle() }
    }

    private fun noArgBool(b: IBinder, desc: String, txn: Int): Boolean {
        val d = Parcel.obtain(); val r = Parcel.obtain()
        return try {
            d.writeInterfaceToken(desc); b.transact(txn, d, r, 0); r.readException(); r.readBoolean()
        } finally { r.recycle(); d.recycle() }
    }

    private fun isFeature(main: IBinder, feat: String): Boolean {
        val d = Parcel.obtain(); val r = Parcel.obtain()
        return try {
            d.writeInterfaceToken(BYDAC); d.writeString(feat)
            main.transact(4, d, r, 0); r.readException(); r.readBoolean()
        } finally { r.recycle(); d.recycle() }
    }

    private fun getIntArray(b: IBinder, desc: String, txn: Int): IntArray? {
        val d = Parcel.obtain(); val r = Parcel.obtain()
        return try {
            d.writeInterfaceToken(desc); b.transact(txn, d, r, 0); r.readException()
            r.createIntArray()
        } catch (_: Throwable) { null }
        finally { r.recycle(); d.recycle() }
    }
}

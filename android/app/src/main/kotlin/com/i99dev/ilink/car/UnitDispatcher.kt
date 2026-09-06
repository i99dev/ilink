package com.i99dev.ilink.car

import android.util.Log
import com.i99dev.ilink.adb.AdbShellBridge

// Two dispatch paths:
//
//  FAST_ACTIONS  -> direct DashDaemon.setInt via TCP (~5-10 ms).
//                   Tables hold (dt, key, valueFn) derived from testing_case
//                   unit/<comp>/<Unit>.java. Adding a feature = one row.
//
//  UNIT_ACTIONS  -> fallback to spawning the corresponding unit DEX via
//                   adb shell. Slow (~1 s per tap) but needed for flows
//                   that go through byd_airconditioning (fragrance) or
//                   that do multi-step state readbacks.
//
// runAction() prefers FAST path, falls back to UNIT path if not listed.
//
// Dispatch-only: the maps themselves live behind [CarTableSource]. Default
// is [EmptySource] (zero entries — every dispatch fails closed). The real
// table is [EncryptedCarTableSource], swapped in at MainActivity.onCreate
// once the encrypted asset is loaded and verified against the signer SHA.
object UnitDispatcher {
    private const val TAG = "UnitDispatcher"
    private const val TMP = "/data/local/tmp"

    /** Empty-by-default source. Holds the dispatcher in a fail-closed state
     *  until [setSource] swaps in the real (encrypted) table. If the
     *  encrypted asset fails to load, this stays active and every
     *  [runAction] / [runUnit] call returns `unknown action` — the gate
     *  surfaces that as a structured error. No hex constants live here, so
     *  no OEM identifiers ship in classes.dex outside the encrypted blob. */
    private object EmptySource : CarTableSource {
        override fun version() = "empty-v1"
        override fun fastAction(actionId: String): FastAction? = null
        override fun unitAction(actionId: String): UnitAction? = null
        override fun unit(unitName: String): UnitSpec? = null
        override fun knownActionIds(): List<String> = emptyList()
        override fun knownUnitNames(): List<String> = emptyList()
    }

    @Volatile private var source: CarTableSource = EmptySource

    /** Swap the data source. Call once at startup from the encrypted loader.
     *  Idempotent — a second call replaces the source but ongoing dispatches
     *  continue using the reference they read at entry. Logs the version
     *  transition so a field report's dispatch log can be traced to the
     *  source that produced it. Default before any [setSource] call is
     *  [EmptySource] (fail-closed). */
    fun setSource(s: CarTableSource) {
        val from = source.version()
        source = s
        val to = s.version()
        Log.i(TAG, "CarTableSource swapped: $from -> $to")
    }

    /** Version of the currently-loaded source. Surfaces through the
     *  daemonStatus channel for log-correlation. */
    fun sourceVersion(): String = source.version()

    /** Phase-9: expose the active [CarTableSource] so peer services
     *  (CarStatusProviderSource) can reuse the same instance instead of
     *  loading the encrypted asset twice. The reference is volatile;
     *  callers should re-read on each query rather than caching. */
    fun tableSource(): CarTableSource = source

    fun runAction(actionId: String, args: Map<String, Any?>): Map<String, Any?> {
        val src = source
        src.fastAction(actionId)?.let { fast ->
            val value = fast.valueFn(args)
            Log.d(TAG, "FAST $actionId: setInt(dt=${fast.dt}, key=0x${"%x".format(fast.key)}, val=$value)")
            val r = AdbShellBridge.fastSet(fast.dt, fast.key, value)
            val out = linkedMapOf<String, Any?>()
            out["action"] = actionId
            out["dt"] = fast.dt
            out["key"] = "0x${"%x".format(fast.key)}"
            out["value"] = value
            r.forEach { (k, v) -> out[k] = v }
            // Normalize ok/code so UI treats uniformly.
            if (!out.containsKey("ok")) out["ok"] = out["code"] == 0
            return out
        }
        src.unitAction(actionId)?.let { ua ->
            val unit = src.unit(ua.unit) ?: return mapOf("error" to "unknown unit: ${ua.unit}")
            val argList = ua.args(args)
            val cmd = buildUnitCmd(unit, argList)
            Log.d(TAG, "UNIT $actionId -> $cmd")
            val raw = AdbShellBridge.shell(cmd)
            return parseUnitResult(raw, actionId)
        }
        Log.w(TAG, "unknown action: $actionId — no FAST_ACTIONS or UNIT_ACTIONS entry")
        return mapOf(
            "error" to "unknown action: $actionId",
            "known" to src.knownActionIds(),
        )
    }

    fun runUnit(unitId: String, args: List<String>): Map<String, Any?> {
        val unit = source.unit(unitId) ?: return mapOf("error" to "unknown unit: $unitId")
        val raw = AdbShellBridge.shell(buildUnitCmd(unit, args))
        return parseUnitResult(raw, unitId)
    }

    fun knownActions(): List<String> = source.knownActionIds()
    fun knownUnits(): List<String> = source.knownUnitNames()

    /** Telemetry reads. Migrated 12 May 2026 from the encrypted
     *  textproto's `status_keys` block to the hardcoded
     *  [StatusKeyCatalog]. Single Kotlin source of truth — entries
     *  resolve through [BydAutoFeatureIdsCatalog] at first access;
     *  names absent on the current trim drop silently (cross-trim
     *  safe). Source-side fallback removed: empty result now means
     *  the framework catalog itself is unavailable, not "asset not
     *  loaded yet". */
    fun statusKeys(): List<StatusKey> = StatusKeyCatalog.list

    /** Resolve an AIDL route — used by [AcFeatureService] and friends.
     *  Returns null when [EmptySource] is active or when the route_id is
     *  unknown; caller fails closed. */
    fun binderRoute(routeId: String): BinderRoute? = source.binderRoute(routeId)

    private fun buildUnitCmd(unit: UnitSpec, args: List<String>): String {
        val quoted = args.joinToString(" ") { "'${it.replace("'", "'\\''")}'" }
        return "CLASSPATH='$TMP/${unit.dex}' app_process64 / ${unit.className} $quoted"
    }

    private fun parseUnitResult(raw: String, actionId: String): Map<String, Any?> {
        val trimmed = raw.trim()
        val setRe = Regex("setInt\\([^)]+\\)\\s*=\\s*(-?\\d+)\\s+(OK|FAIL)")
        val m = setRe.find(trimmed)
        val out = linkedMapOf<String, Any?>(
            "action" to actionId,
            "stdout" to trimmed,
        )
        if (m != null) {
            val code = m.groupValues[1].toIntOrNull() ?: -1
            out["code"] = code
            out["ok"] = (m.groupValues[2] == "OK")
        } else {
            out["ok"] = !trimmed.startsWith("Error:") && trimmed.isNotEmpty()
        }
        return out
    }
}

package com.i99dev.ilink.clusterpatch

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The single source of truth for "which packages did we patch, and at what
 * version". Backs idempotency (don't re-patch an app that's already current
 * — re-patching would duplicate the injected meta-data) and revert
 * detection (the user updated/reinstalled the app from the store → its
 * version changed → our patch is gone → offer to re-patch).
 *
 * Deliberately a small JSON file in `filesDir` rather than Room: the
 * dataset is a handful of rows, this avoids adding a DB dependency, and it
 * stays trivially unit-testable via the [file]-injecting overloads.
 */
object PatchRegistry {
    private const val TAG = "ClusterPatchRegistry"
    private const val FILE_NAME = "cluster_patch_registry.json"

    data class Entry(
        val packageName: String,
        /** versionCode of the patched APK we installed. */
        val patchedVersionCode: Long,
        /** SHA-256 (hex) of the original signer, for restore/audit. */
        val originalSignerSha: String,
        /** [ClusterPatchService.MARKER_VERSION] at patch time. */
        val markerVersion: Int,
        val patchedAtMs: Long,
    )

    private fun fileFor(context: Context) = File(context.filesDir, FILE_NAME)

    /** True if [packageName] is recorded as patched at [currentVersionCode]
     *  with the current [markerVersion]. A version mismatch means the app
     *  was updated/reverted out from under us → not currently patched. */
    fun isCurrentlyPatched(
        context: Context,
        packageName: String,
        currentVersionCode: Long,
        markerVersion: Int,
    ): Boolean = find(fileFor(context), packageName)?.let {
        it.patchedVersionCode == currentVersionCode && it.markerVersion == markerVersion
    } ?: false

    fun record(context: Context, entry: Entry) = write(fileFor(context), entry)

    fun remove(context: Context, packageName: String) = delete(fileFor(context), packageName)

    fun all(context: Context): List<Entry> = readAll(fileFor(context))

    // ---- file-injecting cores (host-unit-testable) ----

    internal fun find(file: File, packageName: String): Entry? =
        readAll(file).firstOrNull { it.packageName == packageName }

    internal fun write(file: File, entry: Entry) {
        val kept = readAll(file).filterNot { it.packageName == entry.packageName }
        persist(file, kept + entry)
    }

    internal fun delete(file: File, packageName: String) {
        val kept = readAll(file).filterNot { it.packageName == packageName }
        persist(file, kept)
    }

    internal fun readAll(file: File): List<Entry> {
        if (!file.exists()) return emptyList()
        return try {
            val arr = JSONArray(file.readText())
            buildList {
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    add(
                        Entry(
                            packageName = o.getString("packageName"),
                            patchedVersionCode = o.getLong("patchedVersionCode"),
                            originalSignerSha = o.optString("originalSignerSha"),
                            markerVersion = o.getInt("markerVersion"),
                            patchedAtMs = o.optLong("patchedAtMs"),
                        ),
                    )
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "registry unreadable, treating as empty: ${t.message}")
            emptyList()
        }
    }

    private fun persist(file: File, entries: List<Entry>) {
        val arr = JSONArray()
        for (e in entries) {
            arr.put(
                JSONObject()
                    .put("packageName", e.packageName)
                    .put("patchedVersionCode", e.patchedVersionCode)
                    .put("originalSignerSha", e.originalSignerSha)
                    .put("markerVersion", e.markerVersion)
                    .put("patchedAtMs", e.patchedAtMs),
            )
        }
        file.parentFile?.mkdirs()
        file.writeText(arr.toString())
    }
}

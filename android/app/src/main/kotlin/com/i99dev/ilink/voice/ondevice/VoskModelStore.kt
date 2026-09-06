package com.i99dev.ilink.voice.ondevice

import android.content.Context
import java.io.File

/**
 * Versioned local Vosk model store. Default English ships in the APK; other
 * compatible versions can be imported or downloaded with explicit consent.
 * Existing models remain usable across app and language changes.
 */
object VoskModelStore {
    /** Root holding one subdir per cached model version. */
    private const val ROOT_DIR = "vosk-models"

    /** Filesystem-safe directory name for a catalog [version]. */
    fun dirName(version: String): String =
        version.replace(Regex("[^A-Za-z0-9._-]"), "_")

    fun rootDir(context: Context): File = File(context.filesDir, ROOT_DIR)

    /** The on-disk directory for [version]'s model. */
    fun modelDir(context: Context, version: String): File =
        File(rootDir(context), dirName(version))

    /**
     * A model for [version] is present iff its dir carries the canonical Kaldi
     * structure (acoustic model + decoding-config). Cheap stat-only check —
     * safe on the hot path.
     */
    fun isPresent(context: Context, version: String): Boolean {
        if (version.isBlank()) return false
        val dir = modelDir(context, version)
        return dir.isDirectory &&
            File(dir, "am/final.mdl").isFile &&
            File(dir, "conf/model.conf").isFile
    }

    /** Absolute path of [version]'s model if present, else null. */
    fun modelPathOrNull(context: Context, version: String): String? =
        if (isPresent(context, version)) modelDir(context, version).absolutePath else null

    /**
     * Delete [version]'s cached model dir, freeing its disk. Layout-agnostic —
     * works for any version dir (Vosk Kaldi tree OR a Moonshine ONNX + .so
     * bundle), since both live at [modelDir]. Returns true if nothing remains
     * on disk afterwards (already-absent counts as success). Best-effort: a
     * partial failure leaves a recoverable dir the next provision overwrites.
     */
    fun deleteModel(context: Context, version: String): Boolean {
        if (version.isBlank()) return false
        val dir = modelDir(context, version)
        if (!dir.exists()) return true
        return dir.deleteRecursively() && !dir.exists()
    }
}

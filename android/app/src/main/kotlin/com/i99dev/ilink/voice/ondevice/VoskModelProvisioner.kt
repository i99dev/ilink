package com.i99dev.ilink.voice.ondevice

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection

/** Local imports and bundled models work offline; curated downloads require owner consent. */
object VoskModelProvisioner {
    private const val TAG = "VoskProvisioner"
    private const val MAX_ATTEMPTS = 4
    private val archivePolicy = ModelArchivePolicy()
    private val provisionLock = Any()
    @Volatile private var downloadsEnabled = false
    @Volatile private var networkGeneration = 0L
    @Volatile private var activeConnection: HttpURLConnection? = null

    @Synchronized fun setDownloadsEnabled(enabled: Boolean) {
        if (downloadsEnabled == enabled) return
        downloadsEnabled = enabled
        networkGeneration++
        if (!enabled) activeConnection?.disconnect()
    }

    private fun requireNetwork(generation: Long) {
        if (!downloadsEnabled || generation != networkGeneration) throw IOException("Model downloads disabled")
    }

    /** Blocking. Serialize staging operations without blocking download-consent revocation. */
    fun provision(
        context: Context,
        zipUrl: String,
        version: String,
        onProgress: (received: Long, total: Long) -> Unit = { _, _ -> },
        isPresent: (Context, String) -> Boolean = VoskModelStore::isPresent,
        allowNetwork: Boolean = false,
    ): Boolean = synchronized(provisionLock) {
        provisionLocked(context, zipUrl, version, onProgress, isPresent, allowNetwork)
    }

    private fun provisionLocked(
        context: Context,
        zipUrl: String,
        version: String,
        onProgress: (Long, Long) -> Unit,
        isPresent: (Context, String) -> Boolean,
        allowNetwork: Boolean,
    ): Boolean {
        if (!version.matches(Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,127}"))) return false
        // Existing model caches are untouched, including locally imported fallback models.
        if (isPresent(context, version)) {
            onProgress(1, 1)
            return true
        }
        val dest = VoskModelStore.modelDir(context, version)
        val name = VoskModelStore.dirName(version)
        val staging = File(context.filesDir, "vosk-stage-$name")
        val zipTmp = File(context.filesDir, "vosk-$name.zip.part")
        try {
            val imported = File(context.filesDir, "voice-import/$name.zip")
            val bundled = context.assets.list("offline/voice")?.contains("$name.zip") == true
            when {
                imported.isFile -> imported.inputStream().use { input ->
                    zipTmp.outputStream().use { archivePolicy.copyArchive(input, it, context.filesDir) }
                }
                bundled -> context.assets.open("offline/voice/$name.zip").use { input ->
                    zipTmp.outputStream().use { archivePolicy.copyArchive(input, it, context.filesDir) }
                }
                allowNetwork && downloadsEnabled -> downloadResumable(zipUrl, zipTmp, onProgress, networkGeneration)
                else -> return false
            }
        } catch (t: Throwable) {
            if (t is ModelPolicyException) zipTmp.delete()
            Log.e(TAG, "provision source failed: ${t.message}", t)
            return false
        }
        return try {
            if (staging.exists() && !staging.deleteRecursively()) throw IOException("Cannot clear model staging")
            if (!staging.mkdirs()) throw IOException("Cannot create model staging")
            val expanded = archivePolicy.extract(zipTmp, staging)
            val root = flattenedRoot(staging)
            dest.parentFile?.mkdirs()
            if (dest.exists() && !dest.deleteRecursively()) throw IOException("Cannot replace invalid model")
            if (!root.renameTo(dest)) {
                archivePolicy.requireSpace(context.filesDir, expanded)
                root.copyRecursively(dest, overwrite = true)
            }
            staging.deleteRecursively()
            zipTmp.delete()
            isPresent(context, version)
        } catch (t: Throwable) {
            Log.e(TAG, "provision unpack failed: ${t.message}", t)
            runCatching { staging.deleteRecursively() }
            runCatching { zipTmp.delete() }
            false
        }
    }

    /** Bound partial files on every attempt; transport failures can resume, policy failures cannot. */
    private fun downloadResumable(
        url: String,
        tmp: File,
        onProgress: (Long, Long) -> Unit,
        generation: Long,
    ) {
        val approvedUrl = ModelDownloadPolicy.validatedUrl(url)
        var lastErr: Throwable? = null
        for (attempt in 1..MAX_ATTEMPTS) {
            var conn: HttpURLConnection? = null
            try {
                requireNetwork(generation)
                val have = if (tmp.exists()) tmp.length() else 0L
                archivePolicy.requireCompressedSize(have)
                conn = (approvedUrl.openConnection() as HttpURLConnection).apply {
                    ModelDownloadPolicy.configure(this)
                    connectTimeout = 30_000
                    readTimeout = 60_000
                    if (have > 0) setRequestProperty("Range", "bytes=$have-")
                }
                activeConnection = conn
                requireNetwork(generation)
                val code = conn.responseCode
                ModelDownloadPolicy.requireStatus(code)
                if (code == 416) {
                    val range = conn.getHeaderField("Content-Range") ?: ""
                    val total = if (range.startsWith("bytes */")) range.removePrefix("bytes */").toLongOrNull() else null
                    if (have <= 0 || total != have) throw ModelPolicyException("Invalid completed model range")
                    return // Extraction still validates the bounded local archive.
                }
                val appending = code == HttpURLConnection.HTTP_PARTIAL
                if (!appending && tmp.exists() && !tmp.delete()) throw IOException("Cannot restart model download")
                val offset = if (appending) have else 0L
                val total = if (appending) ModelDownloadPolicy.requireRange(conn.getHeaderField("Content-Range"), offset) else conn.contentLengthLong
                if (total >= 0) archivePolicy.requireCompressedSize(total)
                conn.inputStream.buffered().use { input ->
                    FileOutputStream(tmp, appending).use { output ->
                        archivePolicy.copyArchive(input, output, tmp.parentFile!!, offset,
                            beforeRead = { requireNetwork(generation) },
                            onProgress = { onProgress(it, total) })
                    }
                }
                requireNetwork(generation)
                if (total >= 0 && tmp.length() != total) throw IOException("Incomplete model response")
                return
            } catch (t: Throwable) {
                if (t is ModelPolicyException) { tmp.delete(); throw t }
                requireNetwork(generation)
                lastErr = t
                Log.w(TAG, "download attempt $attempt/$MAX_ATTEMPTS failed: ${t.message}")
                if (attempt < MAX_ATTEMPTS) Thread.sleep(2_000L * attempt)
            } finally {
                conn?.disconnect()
                if (activeConnection === conn) activeConnection = null
            }
        }
        throw lastErr ?: IOException("Model download failed")
    }

    private fun flattenedRoot(staging: File): File {
        val children = staging.listFiles() ?: return staging
        return if (children.size == 1 && children[0].isDirectory) children[0] else staging
    }
}

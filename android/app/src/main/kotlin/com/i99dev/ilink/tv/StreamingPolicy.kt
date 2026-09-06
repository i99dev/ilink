package com.i99dev.ilink.tv

import android.content.Context
import android.net.Uri
import android.util.AtomicFile
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.io.File
import java.io.IOException

/** Device-owned consent shared with the isolated passenger process. Reading the
 * atomic file avoids Android SharedPreferences' cross-process cache behavior. */
object StreamingPolicy {
    private fun file(context: Context) = AtomicFile(File(context.filesDir, "optional-streaming-policy.v1"))

    fun setEnabled(context: Context, enabled: Boolean) {
        val policy = file(context)
        val out = policy.startWrite()
        try {
            out.write(if (enabled) 1 else 0)
            policy.finishWrite(out)
        } catch (failure: Throwable) {
            policy.failWrite(out)
            throw failure
        }
    }

    fun enabled(context: Context): Boolean = try {
        file(context).openRead().use { it.read() == 1 && it.read() == -1 }
    } catch (_: Exception) { false }

    fun isLocalMedia(url: String): Boolean {
        val uri = Uri.parse(url)
        if (uri.scheme !in setOf("file", "asset") || !uri.host.isNullOrEmpty()) return false
        val path = uri.path.orEmpty().lowercase()
        return listOf(".mp4", ".mkv", ".webm", ".wav", ".mp3", ".aac", ".ogg", ".flac", ".m4a", ".opus")
            .any(path::endsWith)
    }

    fun canPlay(context: Context, url: String): Boolean = isLocalMedia(url) || enabled(context)

    /** Guards every HTTP open, including the next HLS segment after revocation. */
    fun guardedHttp(context: Context, factory: DataSource.Factory): DataSource.Factory = DataSource.Factory {
        val delegate = factory.createDataSource()
        object : DataSource {
            override fun open(spec: DataSpec): Long {
                if (!enabled(context)) throw IOException("Streaming is disabled in Optional Services")
                return delegate.open(spec)
            }
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                if (!enabled(context)) {
                    delegate.close()
                    throw IOException("Streaming consent revoked")
                }
                return delegate.read(buffer, offset, length)
            }
            override fun getUri(): Uri? = delegate.uri
            override fun getResponseHeaders(): Map<String, List<String>> = delegate.responseHeaders
            override fun close() = delegate.close()
            override fun addTransferListener(listener: TransferListener) = delegate.addTransferListener(listener)
        }
    }
}

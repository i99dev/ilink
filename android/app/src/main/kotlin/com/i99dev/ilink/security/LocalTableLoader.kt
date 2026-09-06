package com.i99dev.ilink.security

import android.content.Context
import android.util.Log
import java.io.InputStream

/** Reads public command data covered by the APK signature. No account or key is needed. */
object LocalTableLoader {
    private const val MAX_TABLE_BYTES = 2 * 1024 * 1024

    fun textOrNull(context: Context, name: String): String? = try {
        require(name == "car_table" || name == "mini_app_table")
        context.assets.open("offline/$name.textproto").use { readBounded(it) }
            .toString(Charsets.UTF_8)
    } catch (e: Exception) {
        Log.w("LocalTableLoader", "$name unavailable: ${e.javaClass.simpleName}")
        null
    }

    internal fun readBounded(input: InputStream): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(out.size() + count <= MAX_TABLE_BYTES) { "Dispatch table exceeds size limit" }
            out.write(buffer, 0, count)
        }
        return out.toByteArray()
    }
}

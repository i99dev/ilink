package com.i99dev.ilink.voice.ondevice

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.Locale
import java.util.zip.ZipInputStream

internal class ModelPolicyException(message: String) : IOException(message)

/** Resource limits apply to bytes actually read, including ZIPs with unknown entry sizes. */
internal class ModelArchivePolicy(
    val compressedLimit: Long = 512L * 1024 * 1024,
    private val expandedLimit: Long = 1024L * 1024 * 1024,
    private val fileLimit: Long = 512L * 1024 * 1024,
    private val entryLimit: Int = 4096,
    private val diskReserve: Long = 16L * 1024 * 1024,
) {
    fun requireCompressedSize(size: Long) {
        if (size < 0 || size > compressedLimit) throw ModelPolicyException("Model archive exceeds compressed limit")
    }

    fun requireSpace(directory: File, bytes: Long) {
        if (bytes > directory.usableSpace - diskReserve) {
            throw ModelPolicyException("Insufficient space for speech model")
        }
    }

    fun copyArchive(
        input: InputStream,
        output: OutputStream,
        directory: File,
        startOffset: Long = 0,
        beforeRead: () -> Unit = {},
        onProgress: (Long) -> Unit = {},
    ): Long {
        requireCompressedSize(startOffset)
        val buffer = ByteArray(64 * 1024)
        var received = startOffset
        while (true) {
            beforeRead()
            val n = input.read(buffer)
            if (n < 0) break
            if (n.toLong() > compressedLimit - received) {
                throw ModelPolicyException("Model archive exceeds compressed limit")
            }
            requireSpace(directory, n.toLong())
            output.write(buffer, 0, n)
            received += n
            onProgress(received)
        }
        return received
    }

    /** Caller supplies a fresh private staging directory, never an installed model. */
    fun extract(archive: File, staging: File): Long {
        requireCompressedSize(archive.length())
        val root = staging.canonicalPath + File.separator
        val seen = HashSet<String>()
        var entries = 0
        var expanded = 0L
        val buffer = ByteArray(64 * 1024)
        ZipInputStream(archive.inputStream().buffered()).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                if (++entries > entryLimit) throw ModelPolicyException("Too many model archive entries")
                val name = entry.name.removeSuffix("/")
                val parts = name.split('/')
                if (name.isEmpty() || name.length > 1024 || parts.size > 32 || name.contains('\\') || name.contains(':') ||
                    parts.any { it.isEmpty() || it == "." || it == ".." }) {
                    throw ModelPolicyException("Unsafe model archive path")
                }
                val target = File(staging, name)
                if (!target.canonicalPath.startsWith(root)) throw ModelPolicyException("Model archive escapes staging")
                if (!seen.add(name.lowercase(Locale.ROOT))) throw ModelPolicyException("Duplicate model archive path")
                if (entry.isDirectory) {
                    if (!target.isDirectory && !target.mkdirs()) throw ModelPolicyException("Conflicting model archive path")
                    // Do not let closeEntry silently inflate arbitrary directory payloads.
                    if (zip.read() != -1) throw ModelPolicyException("Directory entry contains data")
                } else {
                    val parent = target.parentFile!!
                    if (!parent.isDirectory && !parent.mkdirs()) throw ModelPolicyException("Conflicting model archive path")
                    if (target.exists()) throw ModelPolicyException("Conflicting model archive path")
                    var fileBytes = 0L
                    target.outputStream().use { output ->
                        while (true) {
                            val n = zip.read(buffer)
                            if (n < 0) break
                            if (n.toLong() > fileLimit - fileBytes || n.toLong() > expandedLimit - expanded) {
                                throw ModelPolicyException("Model archive exceeds expanded limit")
                            }
                            requireSpace(staging, n.toLong())
                            output.write(buffer, 0, n)
                            fileBytes += n
                            expanded += n
                        }
                    }
                }
                zip.closeEntry()
            }
        }
        if (entries == 0) throw ModelPolicyException("Empty model archive")
        return expanded
    }
}

package com.i99dev.ilink.voice.ondevice

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ModelArchivePolicyTest {
    @get:Rule val temporary = TemporaryFolder()

    private fun archive(vararg entries: Pair<String, ByteArray>): File {
        val file = temporary.newFile()
        ZipOutputStream(file.outputStream()).use { zip ->
            for ((name, data) in entries) {
                zip.putNextEntry(ZipEntry(name)) // Sizes deliberately unknown until data descriptor.
                zip.write(data)
                zip.closeEntry()
            }
        }
        return file
    }

    @Test fun actualCopyBytesBoundUnknownLengthAndResume() {
        val policy = ModelArchivePolicy(compressedLimit = 8)
        for (offset in listOf(0L, 5L)) {
            val output = ByteArrayOutputStream()
            assertFailsWith<ModelPolicyException> {
                policy.copyArchive(ByteArrayInputStream(ByteArray(9)), output, temporary.root, offset)
            }
            assertTrue(output.size() + offset <= 8)
        }
        val output = ByteArrayOutputStream()
        assertEquals(8L, policy.copyArchive(ByteArrayInputStream(ByteArray(3)), output, temporary.root, 5))
        assertFailsWith<ModelPolicyException> { policy.requireCompressedSize(9) }
    }

    @Test fun compressedArchiveAndDiskReserveAreEnforced() {
        val zip = archive("model/file" to byteArrayOf(1))
        assertFailsWith<ModelPolicyException> {
            ModelArchivePolicy(compressedLimit = 1).extract(zip, temporary.newFolder())
        }
        assertFailsWith<ModelPolicyException> {
            ModelArchivePolicy(diskReserve = Long.MAX_VALUE).copyArchive(
                ByteArrayInputStream(byteArrayOf(1)), ByteArrayOutputStream(), temporary.root)
        }
    }

    @Test fun highlyCompressedUnknownSizeEntryStopsAtActualPerFileLimit() {
        val zip = archive("model/bomb" to ByteArray(1024 * 1024))
        assertTrue(zip.length() < 4096)
        val stage = temporary.newFolder()
        assertFailsWith<ModelPolicyException> {
            ModelArchivePolicy(fileLimit = 128 * 1024).extract(zip, stage)
        }
        assertTrue(File(stage, "model/bomb").length() <= 128 * 1024)
    }

    @Test fun cumulativeExpansionAndEntryCountAreEnforced() {
        val zip = archive("a" to ByteArray(80), "b" to ByteArray(80))
        assertFailsWith<ModelPolicyException> {
            ModelArchivePolicy(expandedLimit = 100).extract(zip, temporary.newFolder())
        }
        assertFailsWith<ModelPolicyException> {
            ModelArchivePolicy(entryLimit = 1).extract(zip, temporary.newFolder())
        }
    }

    @Test fun traversalAbsolutePathsAndExcessiveMetadataAreRejected() {
        for (name in listOf("../escape", "/absolute", "a/../../escape", "a\\..\\escape",
            "C:/escape", "a/./b", "x".repeat(1025), (1..33).joinToString("/") { "a" })) {
            assertFailsWith<ModelPolicyException>(name) {
                ModelArchivePolicy().extract(archive(name to byteArrayOf(1)), temporary.newFolder())
            }
        }
    }

    @Test fun duplicateCaseAliasesAndDirectoryPayloadsAreRejected() {
        assertFailsWith<ModelPolicyException> {
            ModelArchivePolicy().extract(archive("model/A" to byteArrayOf(1), "model/a" to byteArrayOf(2)), temporary.newFolder())
        }
        assertFailsWith<ModelPolicyException> {
            ModelArchivePolicy().extract(archive("model/" to ByteArray(1024 * 1024)), temporary.newFolder())
        }
        assertFailsWith<ModelPolicyException> {
            ModelArchivePolicy().extract(archive("a/b" to byteArrayOf(1), "a" to byteArrayOf(2)), temporary.newFolder())
        }
    }

    @Test fun onlyExactCuratedPublisherUrlsAreAccepted() {
        val good = "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"
        assertEquals(good, ModelDownloadPolicy.validatedUrl(good).toString())
        for (bad in listOf(good.replace("https:", "http:"), good.replace("alphacephei.com", "evil.example"),
            good.replace("alphacephei.com", "user@alphacephei.com"), good.replace("alphacephei.com", "alphacephei.com:443"),
            "$good?token=x", "$good#x", good.replace("/vosk/", "/other/../vosk/"),
            good.replace("small-en-us-0.15", "unknown"), good.replace("vosk/models/", "vosk/models/%2e%2e/"))) {
            assertFailsWith<ModelPolicyException>(bad) { ModelDownloadPolicy.validatedUrl(bad) }
        }
    }

    @Test fun redirectFollowingIsDisabledAndEveryRedirectStatusRejected() {
        val connection = object : HttpURLConnection(URL("https://alphacephei.com/")) {
            override fun connect() = Unit
            override fun disconnect() = Unit
            override fun usingProxy() = false
        }
        ModelDownloadPolicy.configure(connection)
        assertFalse(connection.instanceFollowRedirects)
        assertEquals("identity", connection.getRequestProperty("Accept-Encoding"))
        for (code in 300..399) assertFailsWith<ModelPolicyException> { ModelDownloadPolicy.requireStatus(code) }
        ModelDownloadPolicy.requireStatus(200)
        ModelDownloadPolicy.requireStatus(206)
    }

    @Test fun resumeMustMatchActualPartialOffsetAndValidTotal() {
        assertEquals(100L, ModelDownloadPolicy.requireRange("bytes 40-99/100", 40))
        for (range in listOf(null, "bytes 0-99/100", "bytes 40-100/100", "bytes 40-99/*", "bytes 40-999999999999999999999/100")) {
            assertFailsWith<ModelPolicyException> { ModelDownloadPolicy.requireRange(range, 40) }
        }
    }

    @Test fun realBundledEnglishExtractsWithinProductionLimits() {
        val zip = File(System.getProperty("offline.assets", "src/main/assets/offline"), "voice/en-0.15.zip")
        assertTrue(zip.isFile, "Bundled English archive must be present")
        val stage = temporary.newFolder()
        val expanded = ModelArchivePolicy().extract(zip, stage)
        val model = File(stage, "vosk-model-small-en-us-0.15")
        assertEquals(15_962_575L, File(model, "am/final.mdl").length())
        assertTrue(File(model, "conf/model.conf").isFile)
        assertTrue(File(model, "graph/HCLr.fst").isFile)
        assertTrue(expanded > zip.length())
        println("Bundled English archive: compressed=${zip.length()} expanded=$expanded")
    }
}

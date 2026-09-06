package com.i99dev.ilink.clusterpatch

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Host-JVM coverage for the pure logic in the M2 device layer. The
 *  shell-bound install steps are validated on AAOS_DiLink_A13. */
class ClusterPatchUnitTest {

    @Test
    fun parsesRealInstallCreateOutput() {
        // Exact string `pm install-create` printed on the emulator.
        assertEquals(2014265636, PrivilegedApkInstaller.parseSessionId("Success: created install session [2014265636]"))
        assertNull(PrivilegedApkInstaller.parseSessionId("Failure [INSTALL_FAILED_INVALID_APK]"))
    }

    @Test
    fun classifiesPmSuccessAndFailure() {
        assertTrue(PrivilegedApkInstaller.isSuccess("Success: streamed 2384 bytes"))
        assertTrue(PrivilegedApkInstaller.isSuccess("Success"))
        assertFalse(PrivilegedApkInstaller.isSuccess("Failure [INSTALL_FAILED_INVALID_APK: ...]"))
        assertFalse(PrivilegedApkInstaller.isSuccess(""))
    }

    @Test
    fun chunkTextIsLosslessAndBounded() {
        val s = buildString { repeat(250_000) { append(('a' + (it % 26))) } }
        val chunks = PrivilegedApkInstaller.chunkText(s, 96 * 1024)
        assertTrue("must split a >96KB string", chunks.size > 1)
        assertTrue("each chunk within bound", chunks.all { it.length <= 96 * 1024 })
        assertEquals("rejoin must equal original", s, chunks.joinToString(""))
        // Small input stays single-shot.
        assertEquals(listOf("tiny"), PrivilegedApkInstaller.chunkText("tiny", 96 * 1024))
    }

    @Test
    fun registryWriteFindUpdateDeleteRoundTrips() {
        val file = File(Files.createTempDirectory("reg").toFile(), "registry.json")
        assertTrue(PatchRegistry.readAll(file).isEmpty())

        val e = PatchRegistry.Entry("com.waze", 100L, "deadbeef", 1, 1_700_000_000_000L)
        PatchRegistry.write(file, e)
        assertEquals(e, PatchRegistry.find(file, "com.waze"))
        assertEquals(1, PatchRegistry.readAll(file).size)

        // Re-write same package replaces, not duplicates.
        val e2 = e.copy(patchedVersionCode = 101L)
        PatchRegistry.write(file, e2)
        assertEquals(1, PatchRegistry.readAll(file).size)
        assertEquals(101L, PatchRegistry.find(file, "com.waze")?.patchedVersionCode)

        PatchRegistry.delete(file, "com.waze")
        assertNull(PatchRegistry.find(file, "com.waze"))
    }
}

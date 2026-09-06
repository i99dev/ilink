package com.i99dev.ilink.clusterpatch

import com.android.apksig.ApkVerifier
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.zip.ZipFile

/**
 * Host JVM test for the M1 patcher core. Patches the bundled
 * `sample.apk` fixture (a minimal app with NO `resizeableActivity`) and
 * asserts:
 *   1. the output APK's signature verifies (apksig), and
 *   2. its binary AndroidManifest now carries `resizeableActivity` and the
 *      `BYD_SUPPORT_SPLIT_ACTIVITY` whitelist marker.
 *
 * It also copies the patched APK to a stable temp path so the on-emulator
 * integration step (aapt2 badging + install) can pick it up — see the
 * commands in docs/plans/CLUSTER_APP_PATCHER_PLAN.md (M1).
 */
class ClusterApkPatcherTest {

    @Test
    fun patchesSampleApkWithClusterDelta() {
        val work = File(System.getProperty("java.io.tmpdir"), "ilink-clusterpatch").apply {
            deleteRecursively(); mkdirs()
        }
        val sample = File(work, "sample.apk")
        javaClass.getResourceAsStream("/clusterpatch/sample.apk")!!
            .use { input -> sample.outputStream().use { input.copyTo(it) } }

        val result = ClusterApkPatcher.patch(
            baseApk = sample,
            splitApks = emptyList(),
            outDir = File(work, "out"),
            minSdkVersion = 29,
            signer = ephemeralSigner(work),
        )

        // 1. Signature verifies.
        val verification = ApkVerifier.Builder(result.base).build().verify()
        assertTrue(
            "patched APK signature must verify (errors=${verification.errors})",
            verification.isVerified,
        )

        // 2. Manifest delta present. Scan the binary AndroidManifest string
        //    pool encoding-agnostically (ARSCLib may emit UTF-8 or UTF-16).
        val manifestBytes = readEntry(result.base, "AndroidManifest.xml")
        assertTrue("resizeableActivity attr must be injected", manifestBytes.containsText("resizeableActivity"))
        assertTrue("BYD whitelist meta-data must be injected", manifestBytes.containsText("BYD_SUPPORT_SPLIT_ACTIVITY"))

        // Hand the artifact to the emulator integration step.
        val stable = File(work, "patched_base.apk")
        result.base.copyTo(stable, overwrite = true)
        println("CLUSTERPATCH_OUT=${stable.absolutePath}")
    }

    /** A new test-only key per run; no shared private-key fixture is shipped. */
    private fun ephemeralSigner(work: File): ApkSigningProvider {
        val keyStoreFile = File(work, "test-identity.jks")
        val password = java.util.UUID.randomUUID().toString()
        val executable = if (System.getProperty("os.name", "").lowercase().contains("win")) "keytool.exe" else "keytool"
        val keytool = File(System.getProperty("java.home"), "bin/$executable")
        val process = ProcessBuilder(keytool.absolutePath, "-genkeypair", "-alias", "test",
            "-keyalg", "RSA", "-keysize", "2048", "-dname", "CN=Ephemeral test",
            "-validity", "1", "-storetype", "JKS", "-keystore", keyStoreFile.absolutePath,
            "-storepass", password, "-keypass", password, "-noprompt")
            .redirectErrorStream(true).start()
        process.inputStream.use { it.readBytes() }
        check(process.waitFor() == 0) { "Could not create ephemeral test identity" }
        val store = java.security.KeyStore.getInstance("JKS")
        keyStoreFile.inputStream().use { store.load(it, password.toCharArray()) }
        val entry = store.getEntry("test", java.security.KeyStore.PasswordProtection(password.toCharArray()))
            as java.security.KeyStore.PrivateKeyEntry
        keyStoreFile.delete()
        return ApkSigningProvider { input, output, minSdk ->
            PatchSigner.signWithIdentity(input, output, minSdk, entry.privateKey,
                entry.certificateChain.map { it as java.security.cert.X509Certificate })
        }
    }

    private fun readEntry(apk: File, name: String): ByteArray =
        ZipFile(apk).use { zip ->
            val entry = zip.getEntry(name) ?: error("$name missing from ${apk.name}")
            zip.getInputStream(entry).readBytes()
        }

    /** Matches the substring whether the AXML string pool is UTF-8 (ASCII
     *  bytes) or UTF-16LE (ASCII interleaved with NUL). */
    private fun ByteArray.containsText(needle: String): Boolean {
        val utf8 = String(this, Charsets.ISO_8859_1)
        val utf16 = String(this, Charsets.UTF_16LE)
        return utf8.contains(needle) || utf16.contains(needle)
    }
}

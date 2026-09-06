package com.i99dev.ilink.clusterpatch

import com.reandroid.apk.ApkModule
import java.io.File

/**
 * M1 core of the cluster-app patcher: turn an installed app's APK set
 * (base + config splits) into a re-signed, cluster-enabled APK set on disk.
 * Pure file-in / file-out — no Android framework, no shell — so it is
 * exercised by a host JVM unit test (`ClusterApkPatcherTest`). Staging +
 * `pm install` over the ADB bridge is M2.
 *
 * Pipeline per call:
 *   base  → manifest delta ([ManifestPatcher]) → strip old sig → rebuild
 *           ([ApkModule.writeApk]) → re-sign ([PatchSigner])
 *   split → strip old sig → rebuild → re-sign (same key; no manifest edit)
 *
 * Every output APK is signed with the one reused key, so the installer
 * accepts the set as a single self-consistent package.
 */
object ClusterApkPatcher {

    /** The re-signed, cluster-enabled APK set, ready for `pm install`. */
    data class PatchedApk(val base: File, val splits: List<File>)

    /**
     * @param baseApk        the target's `ApplicationInfo.sourceDir`
     * @param splitApks      its `splitSourceDirs` (may be empty)
     * @param outDir         scratch dir for outputs (created if absent)
     * @param minSdkVersion  the target's minSdk (drives apksig scheme set)
     */
    fun patch(
        baseApk: File,
        splitApks: List<File>,
        outDir: File,
        minSdkVersion: Int,
        signer: ApkSigningProvider = PatchSigner,
    ): PatchedApk {
        outDir.mkdirs()
        val base = patchBase(baseApk, outDir, minSdkVersion, signer)
        val splits = splitApks.mapIndexed { i, split ->
            resignOnly(split, File(outDir, "patched_split_$i.apk"), outDir, "split_$i", minSdkVersion, signer)
        }
        return PatchedApk(base, splits)
    }

    private fun patchBase(baseApk: File, outDir: File, minSdkVersion: Int, signer: ApkSigningProvider): File {
        val module = ApkModule.loadApkFile(baseApk)
        try {
            ManifestPatcher.applyClusterDelta(module)
            module.removeDir(META_INF)
            module.refreshManifest()
            val unsigned = File(outDir, "patched_base_unsigned.apk")
            module.writeApk(unsigned)
            val signed = File(outDir, "patched_base.apk")
            signer.sign(unsigned, signed, minSdkVersion)
            unsigned.delete()
            return signed
        } finally {
            module.close()
        }
    }

    private fun resignOnly(
        splitApk: File,
        signedOut: File,
        outDir: File,
        tag: String,
        minSdkVersion: Int,
        signer: ApkSigningProvider,
    ): File {
        val module = ApkModule.loadApkFile(splitApk)
        try {
            module.removeDir(META_INF)
            val unsigned = File(outDir, "${tag}_unsigned.apk")
            module.writeApk(unsigned)
            signer.sign(unsigned, signedOut, minSdkVersion)
            unsigned.delete()
            return signedOut
        } finally {
            module.close()
        }
    }

    private const val META_INF = "META-INF"
}

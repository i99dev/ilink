package com.i99dev.ilink.clusterpatch

import android.content.Context
import android.content.pm.PackageManager
import android.util.Log

/**
 * Device-level orchestration of the cluster-app patch: resolve → patch →
 * install → record. The one entry point the higher layers (the
 * native-first cast coordinator in M3, the UI in M4) call.
 *
 * This is the *remediation* half of the two-tier cast: it runs only after
 * a native cluster cast has been refused and the user has consented. It
 * does NOT decide whether to patch — it executes a patch.
 */
object ClusterPatchService {

    private const val TAG = "ClusterPatchService"

    /** Bumped when [ManifestPatcher]'s delta changes, so [PatchRegistry]
     *  can tell an old patch from a current one and trigger a re-patch. */
    const val MARKER_VERSION = 1

    sealed interface Outcome {
        object Patched : Outcome
        object AlreadyPatched : Outcome
        /** Undo restored the backed-up original APK. */
        object Restored : Outcome
        /** Undo removed the patched app but had no backup to restore — the
         *  user must reinstall the original from the store. */
        object Removed : Outcome
        /** [stage] ∈ {resolve, patch, stage, create, write, commit, restore}. */
        data class Failed(val stage: String, val detail: String) : Outcome
    }

    /**
     * Patch [packageName] and replace its install. Idempotent: returns
     * [Outcome.AlreadyPatched] if the registry shows it already patched at
     * its current version with the current marker.
     *
     * @param nowMs injectable clock for tests.
     */
    fun patchAndInstall(
        context: Context,
        packageName: String,
        nowMs: Long = System.currentTimeMillis(),
    ): Outcome {
        val src = try {
            ApkSource.resolve(context, packageName)
        } catch (t: Throwable) {
            return Outcome.Failed("resolve", t.message ?: t.javaClass.simpleName)
        }

        if (PatchRegistry.isCurrentlyPatched(context, packageName, src.versionCode, MARKER_VERSION)) {
            return Outcome.AlreadyPatched
        }

        // Capture the ORIGINAL signer before we replace it (post-install the
        // package carries our reused key, so this must be read up front).
        val originalSignerSha = originalSignerSha(context, packageName)

        // Fast path: patch + re-sign + install ENTIRELY on-device (shell uid via
        // app_process), reading /data/app and writing /data/local/tmp locally.
        // Nothing big crosses the ADB connection — a 189 MB app patches in ~the
        // time of a local pm install instead of minutes of base64 staging. The
        // on-device step also backs up the originals locally for [unpatch].
        return when (val r = OnDeviceClusterPatch.patch(context, packageName)) {
            is OnDeviceClusterPatch.Result.Ok -> {
                PatchRegistry.record(
                    context,
                    PatchRegistry.Entry(
                        packageName = packageName,
                        patchedVersionCode = src.versionCode,
                        originalSignerSha = originalSignerSha,
                        markerVersion = MARKER_VERSION,
                        patchedAtMs = nowMs,
                    ),
                )
                Outcome.Patched
            }
            is OnDeviceClusterPatch.Result.Failed -> Outcome.Failed("patch", r.detail)
        }
    }

    /**
     * Undo a patch — on-device restore of the locally backed-up originals
     * (uninstall the patched build + reinstall the originals), else remove.
     * The backup lives in /data/local/tmp (written at patch time); if it's
     * gone (e.g. a reboot cleared tmp) the on-device step removes the patched
     * app and the user reinstalls the original from the store.
     */
    fun unpatch(context: Context, packageName: String): Outcome {
        return when (val r = OnDeviceClusterPatch.unpatch(context, packageName)) {
            is OnDeviceClusterPatch.Result.Ok -> {
                PatchRegistry.remove(context, packageName)
                Outcome.Restored
            }
            is OnDeviceClusterPatch.Result.Failed -> Outcome.Failed("restore", r.detail)
        }
    }

    /** Best-effort SHA-256 (hex) of the original APK signer; "" if unknown. */
    private fun originalSignerSha(context: Context, packageName: String): String = try {
        val pi = context.packageManager.getPackageInfo(
            packageName,
            PackageManager.GET_SIGNING_CERTIFICATES,
        )
        val sig = pi.signingInfo?.apkContentsSigners?.firstOrNull()
        if (sig == null) "" else toHex(com.i99dev.ilink.security.CryptoUtils.sha256(sig.toByteArray()))
    } catch (t: Throwable) {
        Log.w(TAG, "could not read original signer for $packageName: ${t.message}")
        ""
    }

    private fun toHex(bytes: ByteArray): String {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) sb.append("%02x".format(b.toInt() and 0xff))
        return sb.toString()
    }
}

package com.i99dev.ilink.clusterpatch

import android.content.Context
import android.util.Log
import com.i99dev.ilink.adb.AdbShellBridge

/**
 * App side of the on-device patcher: resolves the target's APK paths, then
 * spawns [OnDevicePatch] as shell uid via `app_process64` over the loopback ADB
 * bridge. The heavy work (read /data/app → patch+sign → pm install) happens
 * entirely on the device, so a 189 MB app patches in ~the time of a local
 * `pm install` instead of minutes of base64 staging.
 */
object OnDeviceClusterPatch {

    private const val ENTRY = "com.i99dev.ilink.clusterpatch.OnDevicePatchKt"
    private const val TAG = "OnDeviceClusterPatch"

    sealed interface Result {
        data object Ok : Result
        data class Failed(val detail: String) : Result
    }

    /** Query only public identity from the same UID/Keystore namespace that signs. */
    fun signerSha(context: Context): String? {
        val apk = context.applicationInfo.sourceDir
        val out = AdbShellBridge.shell("CLASSPATH='$apk' app_process64 /system/bin $ENTRY signer", 30_000)
        return Regex("I99_PATCH_SIGNER:([a-f0-9]{64})").find(out)?.groupValues?.get(1)
    }

    fun patch(context: Context, packageName: String): Result {
        val src = ApkSource.resolve(context, packageName)
        val ourApk = context.applicationInfo.sourceDir
        val parts = (listOf(src.base) + src.splits).joinToString(" ") { "'${it.absolutePath}'" }
        val cmd = "CLASSPATH='$ourApk' app_process64 /system/bin $ENTRY patch " +
            "$packageName ${src.minSdk} $parts"
        Log.i(TAG, "patch $packageName via on-device app_process (${src.splits.size} splits)")
        val out = AdbShellBridge.shell(cmd, TIMEOUT_MS)
        return when {
            out.contains("I99_PATCH_OK") -> Result.Ok
            // The patch failed AND the rollback also failed → the app is gone.
            out.contains("I99_PATCH_FAILED_APP_REMOVED") -> Result.Failed(
                "patch failed and the original couldn't be restored — $packageName was " +
                    "removed; reinstall it from the store. (${reasonOf(out, "I99_PATCH_FAILED_APP_REMOVED:")})",
            )
            else -> Result.Failed(reasonOf(out, "I99_PATCH_FAILED:"))
        }
    }

    fun unpatch(context: Context, packageName: String): Result {
        val ourApk = context.applicationInfo.sourceDir
        val cmd = "CLASSPATH='$ourApk' app_process64 /system/bin $ENTRY unpatch $packageName"
        val out = AdbShellBridge.shell(cmd, TIMEOUT_MS)
        return if (out.contains("I99_UNPATCH_OK") || out.contains("I99_UNPATCH_REMOVED")) {
            Result.Ok
        } else {
            Result.Failed(reasonOf(out, "I99_PATCH_FAILED:"))
        }
    }

    private fun reasonOf(out: String, marker: String): String =
        if (out.contains(marker)) out.substringAfter(marker).trim().take(160)
        else out.takeLast(160).trim().ifEmpty { "no output" }

    private const val TIMEOUT_MS = 600_000L
}

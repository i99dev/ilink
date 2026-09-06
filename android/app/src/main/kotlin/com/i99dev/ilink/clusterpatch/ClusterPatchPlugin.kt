package com.i99dev.ilink.clusterpatch

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * `ilink/cluster_patch` — the Flutter bridge for the cluster-app patcher.
 * The *remediation* surface of the two-tier cast: the Dart side offers it
 * only after a native cluster cast was refused and the user consented.
 *
 * Methods:
 *   * `probe`   {packageName} → {capability, alreadyPatched, reason}
 *       capability ∈ AMBER (eligible) | GREEN (already patched) | RED
 *       (blocked — system/own app; re-signing would brick or is pointless).
 *   * `patch`   {packageName} → {outcome, stage?, detail?}
 *       outcome ∈ patched | already_patched | failed.
 *   * `unpatch` {packageName} → {ok}
 *       removes our patched build (user reinstalls the original from store).
 *
 * `patch`/`unpatch` do disk + shell I/O and take seconds, so every call
 * runs on a worker thread and the [MethodChannel.Result] is posted back on
 * the main looper (Flutter requires results on the platform thread).
 */
class ClusterPatchPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "cluster-patch") }
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // No package argument — returns every package we've patched (for the
        // "Patched" badges in the Cluster-apps settings list).
        if (call.method == "patchedList") {
            onWorker(result) {
                val ours = ourSignerSha()
                // Trust the signer, not just the registry: keep only packages
                // still installed WITH our key; prune entries that were
                // reinstalled/reverted so the badges never go stale.
                val verified = PatchRegistry.all(context).map { it.packageName }.filter { p ->
                    val actual = installedSignerSha(p)
                    val ok = actual != null && (actual.equals(ours, ignoreCase = true) ||
                        actual.equals(legacySignerSha(), ignoreCase = true))
                    // An unavailable local ADB/Keystore must not erase patch history.
                    if (!ok && ours != null) PatchRegistry.remove(context, p)
                    ok
                }
                mapOf("packages" to verified)
            }
            return
        }
        val pkg = call.argument<String>("packageName")
        if (pkg.isNullOrBlank()) {
            result.error("bad_request", "packageName required", null)
            return
        }
        when (call.method) {
            "probe" -> onWorker(result) { probe(pkg) }
            "patch" -> onWorker(result) { outcomeToMap(ClusterPatchService.patchAndInstall(context, pkg)) }
            "unpatch" -> onWorker(result) { unpatchToMap(ClusterPatchService.unpatch(context, pkg)) }
            else -> result.notImplemented()
        }
    }

    /** Run [block] off the platform thread; marshal its result (or error)
     *  back on the main looper. */
    private fun onWorker(result: MethodChannel.Result, block: () -> Map<String, Any?>) {
        worker.execute {
            val out = try {
                Result.success(block())
            } catch (t: Throwable) {
                Log.e(TAG, "cluster_patch op failed", t)
                Result.failure(t)
            }
            main.post {
                out.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { result.error("cluster_patch_error", it.message ?: it.javaClass.simpleName, null) },
                )
            }
        }
    }

    private fun probe(pkg: String): Map<String, Any?> = try {
        val ai = context.packageManager.getApplicationInfo(pkg, 0)
        val isSystem = (ai.flags and ApplicationInfo.FLAG_SYSTEM) != 0 &&
            (ai.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) == 0
        val isSelf = pkg == context.packageName
        // Ground truth: an app is patched iff its INSTALLED signer is our
        // cluster-patch key — not whatever the registry remembers. So a fresh
        // reinstall of the original (different signer) correctly reads as
        // not-patched, even at the same versionCode.
        val actual = installedSignerSha(pkg)
        val alreadyPatched = actual != null && (actual.equals(ourSignerSha(), ignoreCase = true) ||
            actual.equals(legacySignerSha(), ignoreCase = true))
        val capability = when {
            isSelf -> "RED"
            isSystem -> "RED"
            alreadyPatched -> "GREEN"
            else -> "AMBER"
        }
        mapOf(
            "capability" to capability,
            "alreadyPatched" to alreadyPatched,
            "reason" to when {
                isSelf -> "self"
                isSystem -> "system_app"
                else -> null
            },
        )
    } catch (t: Throwable) {
        mapOf("capability" to "RED", "alreadyPatched" to false, "reason" to (t.message ?: "not_found"))
    }

    private fun outcomeToMap(o: ClusterPatchService.Outcome): Map<String, Any?> = when (o) {
        is ClusterPatchService.Outcome.Patched -> mapOf("outcome" to "patched")
        is ClusterPatchService.Outcome.AlreadyPatched -> mapOf("outcome" to "already_patched")
        is ClusterPatchService.Outcome.Failed -> mapOf("outcome" to "failed", "stage" to o.stage, "detail" to o.detail)
        else -> mapOf("outcome" to "failed", "detail" to "unexpected") // patch never restores/removes
    }

    private fun unpatchToMap(o: ClusterPatchService.Outcome): Map<String, Any?> = when (o) {
        is ClusterPatchService.Outcome.Restored -> mapOf("result" to "restored")
        is ClusterPatchService.Outcome.Removed -> mapOf("result" to "removed")
        is ClusterPatchService.Outcome.Failed -> mapOf("result" to "failed", "stage" to o.stage, "detail" to o.detail)
        else -> mapOf("result" to "failed", "detail" to "unexpected")
    }

    // --- signer identity (ground-truth "is it patched") ---

    private var cachedOurSha: String? = null

    /** The signing process owns its Keystore; only its public fingerprint crosses UID. */
    private fun ourSignerSha(): String? = cachedOurSha ?: run {
        OnDeviceClusterPatch.signerSha(context)?.also { cachedOurSha = it }
    }

    /** Public legacy certificate identifies already-patched apps; never signs new ones. */
    private fun legacySignerSha(): String {
        val der = javaClass.getResourceAsStream("/cluster_patch/patch_cert.der")!!.use { it.readBytes() }
        return sha256Hex(der)
    }

    /** SHA-256 (hex) of [pkg]'s current installed signer, or null. */
    private fun installedSignerSha(pkg: String): String? = try {
        val pi = context.packageManager.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES)
        pi.signingInfo?.apkContentsSigners?.firstOrNull()?.let { sha256Hex(it.toByteArray()) }
    } catch (t: Throwable) {
        null
    }

    private fun sha256Hex(bytes: ByteArray): String {
        val d = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
        val sb = StringBuilder(d.size * 2)
        for (x in d) sb.append("%02x".format(x.toInt() and 0xff))
        return sb.toString()
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    companion object {
        private const val TAG = "ClusterPatchPlugin"
        private const val CHANNEL = "ilink/cluster_patch"
    }
}

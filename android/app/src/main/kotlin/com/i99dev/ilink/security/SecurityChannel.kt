package com.i99dev.ilink.security

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File

/**
 * Local command audit, integrity status and legacy-cache diagnostics/reset.
 * Remote telemetry draining and account-issued table/secret writers have
 * been retired. Existing on-device encrypted cache readers remain intact.
 */
class SecurityChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "ilink/security")

    fun register() {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "logDispatch" -> {
                        val cmd = call.argument<String>("cmd") ?: ""
                        val args = call.argument<String>("args") ?: ""
                        val outcome = call.argument<String>("outcome") ?: "unknown"
                        val latency = call.argument<Number>("latency_ms")?.toLong() ?: 0L
                        SecureLogger.get()?.emitDispatch(cmd, args, outcome, latency)
                        result.success(true)
                    }
                    "logBurst" -> {
                        val cls = call.argument<String>("class") ?: ""
                        val started = call.argument<Boolean>("started") ?: false
                        SecureLogger.get()?.emitBurst(cls, started)
                        result.success(true)
                    }
                    "logIntegrity" -> {
                        val subject = call.argument<String>("subject") ?: ""
                        val expected = call.argument<String>("expected") ?: ""
                        val actual = call.argument<String>("actual") ?: ""
                        SecureLogger.get()?.emitIntegrity(subject, expected, actual)
                        result.success(true)
                    }
                    "integrityHealthy" -> {
                        result.success(IntegrityMonitor.get()?.isHealthy() ?: true)
                    }
                    "v2TableEtag" -> {
                        // Read-only compatibility metadata for local diagnostics.
                        val kind = v2KindOrNull(call.argument<String>("kind"))
                        result.success(
                            if (kind != null &&
                                v2BlobFile(kind).exists() &&
                                v2EtagFile(kind).exists()
                            ) {
                                v2EtagFile(kind).readText()
                            } else {
                                null
                            },
                        )
                    }
                    "v2Diag" -> {
                        // One-shot v2 load diagnostic (debug aid): why does
                        // EncryptedCarTableSource.loadOrNull return null on a
                        // car that has the blob on disk? Reports secret
                        // presence, blob size, the live source version, and
                        // the actual car_table decrypt outcome. No secret
                        // material crosses the channel — only presence/sizes.
                        val sb = StringBuilder()
                        val secret = try {
                            LegacyTableSecretStore.get(context)
                        } catch (e: Throwable) {
                            null
                        }
                        sb.append("secret=")
                            .append(secret?.let { "present(${it.size}B)" } ?: "MISSING")
                        val signer = try {
                            DeviceKeyMaterial.fromContext(context).signerSha
                        } catch (e: Throwable) {
                            ByteArray(0)
                        }
                        sb.append(" signer=")
                            .append(if (signer.isEmpty()) "?" else hexOf(signer).take(12))
                        for (k in V2_KINDS) {
                            val f = v2BlobFile(k)
                            sb.append(" $k=")
                                .append(if (f.exists()) "${f.length()}B" else "ABSENT")
                        }
                        sb.append(" carSrc=")
                            .append(com.i99dev.ilink.car.UnitDispatcher.sourceVersion())
                        val dec = try {
                            when {
                                secret == null -> "noSecret"
                                signer.isEmpty() -> "noSigner"
                                !v2BlobFile("car_table").exists() -> "noFile"
                                else -> {
                                    val key = CryptoUtils.deriveTableKeyV2(
                                        secret,
                                        signer,
                                        DeviceKeyMaterial.BUILD_SALT,
                                        "car_table.v2",
                                    )
                                    val pt = CryptoUtils.decryptAesGcm(
                                        v2BlobFile("car_table").readBytes(),
                                        key,
                                    )
                                    "OK(${pt.size}B)"
                                }
                            }
                        } catch (e: Throwable) {
                            "FAIL(${e.javaClass.simpleName})"
                        }
                        sb.append(" carDecrypt=").append(dec)
                        result.success(sb.toString())
                    }
                    "clearServerSecret" -> {
                        // Logout / wipe path. Nukes the wrapped secret
                        // AND the Keystore wrap key — previously-stored
                        // v2 blobs become permanently undecryptable.
                        LegacyTableSecretStore.clear(context)
                        for (k in V2_KINDS) {
                            v2BlobFile(k).delete()
                            v2EtagFile(k).delete()
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                Log.w(TAG, "${call.method} failed: ${t.message}")
                result.success(false)
            }
        }
    }

    /** Lowercase-hex of [bytes], `%02x` per byte. Matches the v1
     *  convention ([CryptoUtils] release-key input + [DeviceKeyMaterial]
     *  device-key input), preserving the exact
     *  raw signer-SHA bytes for the HKDF IKM. */
    private fun hexOf(bytes: ByteArray): String {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) sb.append(String.format("%02x", b))
        return sb.toString()
    }

    // ── v2 dispatch-table files (per kind) ───────────────────────────
    // `kind` is interpolated into a filename, so it MUST be validated
    // against the allowlist before use (defense against path traversal).
    private fun v2KindOrNull(kind: String?): String? =
        if (kind != null && kind in V2_KINDS) kind else null

    private fun v2BlobFile(kind: String) = File(context.filesDir, "$kind.v2.pb.enc")

    private fun v2EtagFile(kind: String) = File(context.filesDir, "$kind.v2.etag")

    companion object {
        private const val TAG = "SecurityChannel"

        // Existing per-install v2 dispatch table filenames.
        // Matches V2_FILE in EncryptedCarTableSource / EncryptedMiniAppTableSource.
        private val V2_KINDS = setOf("car_table", "mini_app_table")
    }
}

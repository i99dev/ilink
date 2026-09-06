package com.i99dev.ilink.security

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import java.security.MessageDigest

/**
 * Runtime verification that the APK was signed by the expected release key.
 *
 * Defends against the "repackage + re-sign" attack: an attacker pulls the
 * APK, modifies bytecode (e.g. disables [IntegrityMonitor], swaps the
 * MQTT broker URL, ships a forged car_table.pb.enc with their own action
 * list) and re-signs with a self-generated key. The repacked APK installs
 * fine, but [SignaturePin.verify] sees a signer SHA that isn't ours and
 * the result lets [IntegrityMonitor] raise a tamper flag.
 *
 * What this DOES protect:
 *   - Modified APKs re-signed by anyone other than the holder of
 *     dash-release.jks
 *   - Stripped APKs (re-signed without our cert at all)
 *
 * What this does NOT protect against:
 *   - An attacker who steals dash-release.jks. Sign-key compromise is
 *     out of scope here; mitigation is keystore secrecy + key rotation
 *     in a future release.
 *   - A native-side attacker who NOPs out the comparison after-the-fact.
 *     Defence is layering: [TamperProbes] catches the Frida/debugger
 *     state that would be needed to make that NOP stick.
 *
 * Wiring:
 *   - The expected SHA is provided at build time via the
 *     `DASH_EXPECTED_SIGNER_SHA` Gradle/dart-define. The build.gradle
 *     reads it from the same .env that supplies the keystore, derives the
 *     hex SHA-256 of the cert bytes (matching DeviceKeyMaterial's
 *     calculation), and bakes it into BuildConfig + dart-defines.
 *   - On first call this class queries PackageManager for the
 *     installed APK's signing cert, computes the same SHA, and compares.
 *   - The comparison is constant-time so timing oracles don't leak the
 *     expected value.
 */
object SignaturePin {

    /** Outcome of a single verification call. */
    sealed class Result {
        /** Cert SHA matched the build-time expected value. */
        object Match : Result()

        /** Cert SHA did NOT match. The actual SHA is provided so callers
         *  can include it in tamper telemetry — it isn't a secret on a
         *  repackaged device, the attacker already knows their own key. */
        data class Mismatch(val actualSha: String) : Result()

        /** No expected SHA was baked in (debug build, or build.gradle not
         *  configured). Behaviour: treat as PASS, log warning. Callers
         *  should NOT treat this as tamper — it would false-positive every
         *  developer's local build. */
        object NoBaseline : Result()

        /** PackageManager threw or returned no signature. Treat as
         *  inconclusive — better than false-positive on first launch. */
        data class Unavailable(val reason: String) : Result()
    }

    private const val TAG = "SignaturePin"

    @Volatile private var cached: Result? = null

    /**
     * Verify the running APK's signing cert. Cached after the first call
     * — the signer can't change at runtime, so re-querying just burns CPU.
     *
     * @param expectedHex 64-char hex SHA-256 of the SubjectKeyInfo of
     *                    the first signing certificate. Pass `null` /
     *                    empty for "no baseline configured" → returns
     *                    [Result.NoBaseline].
     */
    fun verify(context: Context, expectedHex: String?): Result {
        cached?.let { return it }
        val r = computeResult(context, expectedHex)
        cached = r
        when (r) {
            is Result.Match -> Log.i(TAG, "signer SHA matches baseline")
            is Result.Mismatch -> Log.w(TAG, "signer SHA mismatch — repackaged APK suspected")
            is Result.NoBaseline -> Log.w(TAG, "no baseline signer SHA configured — skipping check")
            is Result.Unavailable -> Log.w(TAG, "signer query failed: ${r.reason}")
        }
        return r
    }

    private fun computeResult(context: Context, expectedHex: String?): Result {
        val expected = expectedHex?.trim()?.lowercase()?.takeIf { it.length == 64 }
            ?: return Result.NoBaseline

        val signerSha = currentSignerSha(context.packageManager, context.packageName)
            ?: return Result.Unavailable("no signing cert returned")

        val actual = signerSha.toHex()
        return if (constantTimeEquals(expected, actual)) {
            Result.Match
        } else {
            Result.Mismatch(actual)
        }
    }

    /** Compute SHA-256 of the first signing certificate's encoded bytes —
     *  exact same calculation as [DeviceKeyMaterial.firstSigningSha], so
     *  the build-time encrypter and runtime pin can use one shared value. */
    @Suppress("DEPRECATION")
    private fun currentSignerSha(pm: PackageManager, pkg: String): ByteArray? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES)
                val sigs = info.signingInfo?.apkContentsSigners
                    ?: info.signingInfo?.signingCertificateHistory
                val first = sigs?.firstOrNull()?.toByteArray() ?: return null
                MessageDigest.getInstance("SHA-256").digest(first)
            } else {
                val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNATURES)
                val first = info.signatures?.firstOrNull()?.toByteArray() ?: return null
                MessageDigest.getInstance("SHA-256").digest(first)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "PackageManager query threw: ${e.javaClass.simpleName}: ${e.message}")
            null
        }
    }

    /** Constant-time string compare. We're matching hex strings derived
     *  from a known-public hash, so the timing oracle risk is low — but
     *  comparing in constant time costs a few ns and removes one entire
     *  class of attack from the surface. Never use [String.equals] for
     *  cryptographic comparisons. */
    private fun constantTimeEquals(a: String, b: String): Boolean {
        if (a.length != b.length) return false
        var diff = 0
        for (i in a.indices) {
            diff = diff or (a[i].code xor b[i].code)
        }
        return diff == 0
    }

    private fun ByteArray.toHex(): String {
        val sb = StringBuilder(size * 2)
        for (b in this) sb.append(String.format("%02x", b))
        return sb.toString()
    }
}

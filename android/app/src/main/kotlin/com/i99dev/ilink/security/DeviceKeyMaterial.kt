package com.i99dev.ilink.security

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import java.security.MessageDigest
import javax.crypto.SecretKey

/**
 * Collects the device-bound and signer-bound inputs to [CryptoUtils.deriveTableKey].
 * Isolated here so tests can inject fixed bytes instead of touching
 * PackageManager / Settings.
 */
class DeviceKeyMaterial private constructor(
    private val deviceIdBytes: ByteArray,
    private val signerShaBytes: ByteArray,
    private val salt: ByteArray,
) {
    /** Public certificate digest used by retained compatibility readers. */
    val signerSha: ByteArray get() = signerShaBytes

    /** Retained device-local cache/log key format. Persisted key copies use
     *  [KeystoreWrap], but wrapping does not make this derivation secret:
     *  the device ID plus public signer digest and salt reconstruct it.
     *  Hardware backing of the wrapping key depends on the device. */
    fun deriveDeviceKey(): SecretKey =
        CryptoUtils.deriveDeviceKey(deviceIdBytes, signerShaBytes, salt)

    /** Publicly reproducible compatibility key for older encrypted assets.
     *  Fresh standalone assets do not need a build-time encryption step. */
    fun deriveReleaseKey(): SecretKey =
        CryptoUtils.deriveReleaseKey(signerShaBytes, salt)

    companion object {
        /**
         * Build-salt. Static per release — a stable input that couples the
         * key to this binary. Ships as a non-secret (public in the APK) but
         * an attacker also needs [deviceIdBytes] and [signerShaBytes] to
         * reproduce the key, so the salt's job is domain separation, not
         * secrecy.
         */
        // Visible to other security/* classes that derive keys with the
        // same domain separator (e.g. CryptoUtils.deriveTableKeyV2 +
        // EncryptedCarTableSource v2 path). Public ABI is intentional.
        val BUILD_SALT: ByteArray = byteArrayOf(
            // "byd-dash-v1" — spelled byte-by-byte so rot-on-rename is obvious.
            0x62, 0x79, 0x64, 0x2d, 0x64, 0x61, 0x73, 0x68, 0x2d, 0x76, 0x31
        )

        @SuppressLint("HardwareIds")
        fun fromContext(context: Context): DeviceKeyMaterial {
            val deviceId = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ANDROID_ID,
            ) ?: "unknown-device"
            val pkg = context.packageName
            val sig = firstSigningSha(context.packageManager, pkg)
            return DeviceKeyMaterial(
                deviceIdBytes = deviceId.toByteArray(Charsets.UTF_8),
                signerShaBytes = sig,
                salt = BUILD_SALT,
            )
        }

        /** Test-only constructor — bypasses Android APIs. */
        fun forTest(
            deviceId: ByteArray,
            signerSha: ByteArray,
            salt: ByteArray = BUILD_SALT,
        ): DeviceKeyMaterial = DeviceKeyMaterial(deviceId, signerSha, salt)

        private fun firstSigningSha(pm: PackageManager, pkg: String): ByteArray {
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    @Suppress("DEPRECATION")
                    val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES)
                    val sigs = info.signingInfo?.apkContentsSigners
                        ?: info.signingInfo?.signingCertificateHistory
                    val first = sigs?.firstOrNull()?.toByteArray()
                    if (first != null) MessageDigest.getInstance("SHA-256").digest(first)
                    else byteArrayOf()
                } else {
                    @Suppress("DEPRECATION")
                    val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNATURES)
                    val first = info.signatures?.firstOrNull()?.toByteArray()
                    if (first != null) MessageDigest.getInstance("SHA-256").digest(first)
                    else byteArrayOf()
                }
            } catch (_: Throwable) {
                byteArrayOf()
            }
        }
    }
}

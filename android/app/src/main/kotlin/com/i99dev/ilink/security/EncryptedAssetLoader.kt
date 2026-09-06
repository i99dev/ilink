package com.i99dev.ilink.security

import android.content.Context
import android.util.Log
import javax.crypto.SecretKey

/**
 * Reads an encrypted asset from the APK, decrypts it once, and returns the
 * plaintext bytes. Never caches plaintext on disk; callers are responsible
 * for holding the bytes only as long as needed.
 *
 * Safe fallback: if the asset isn't present in the APK, returns null and
 * lets the caller fall back to bundled / pre-staged resources. This means
 * dropping the encrypted assets into the build is the only step that
 * "activates" the encrypted path — no gated flags, no dead code branches.
 */
object EncryptedAssetLoader {
    private const val TAG = "EncAssetLoader"

    /**
     * @return decrypted plaintext, or null if the asset isn't in the APK.
     *         Throws [javax.crypto.AEADBadTagException] if the asset IS
     *         present but fails GCM authentication — callers should let
     *         that propagate so tamper fails closed.
     */
    fun loadOrNull(context: Context, assetPath: String, key: SecretKey): ByteArray? {
        val blob = readAssetOrNull(context, assetPath) ?: return null
        Log.d(TAG, "decrypting $assetPath (${blob.size} bytes)")
        return CryptoUtils.decryptAesGcm(blob, key)
    }

    private fun readAssetOrNull(context: Context, path: String): ByteArray? {
        return try {
            context.assets.open(path).use { it.readBytes() }
        } catch (_: Throwable) {
            null
        }
    }
}

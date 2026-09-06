package com.i99dev.ilink.security

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Device-local wrapping with an Android Keystore AES key. Hardware backing
 * depends on the device/provider; this implementation does not require or
 * attest StrongBox/TEE protection.
 *
 * Wrapping protects the persisted copy of a key. It does not make a payload
 * key derived from observable ANDROID_ID, signer and public salt impossible
 * to recompute independently. Rooted runtime access remains outside this
 * storage boundary. Existing aliases and formats are retained for upgrades.
 */
object KeystoreWrap {
    private const val TAG = "KeystoreWrap"
    private const val PROVIDER = "AndroidKeyStore"
    private const val KEY_ALIAS = "dash-wrap-v1"
    private const val GCM_TAG_BITS = 128
    private const val GCM_NONCE_BYTES = 12

    /** Wire format of a wrapped blob: nonce(12) || ciphertext || tag(16). */
    fun wrap(plaintext: ByteArray): ByteArray {
        val key = ensureKey()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        // Keystore-generated cipher provides its own random nonce; pull
        // it back so we can prepend it to the output (unwrap needs it).
        val nonce = cipher.iv ?: error("AndroidKeyStore did not produce an IV")
        require(nonce.size == GCM_NONCE_BYTES) {
            "unexpected IV length: ${nonce.size}"
        }
        val ct = cipher.doFinal(plaintext)
        return nonce + ct
    }

    /** Inverse of [wrap]. Throws on tamper, missing key, or wrong device. */
    fun unwrap(blob: ByteArray): ByteArray {
        require(blob.size > GCM_NONCE_BYTES + (GCM_TAG_BITS / 8)) {
            "wrapped blob too short"
        }
        val key = loadKey() ?: throw IllegalStateException(
            "wrap key missing — first launch on this device, or KeyStore was reset"
        )
        val nonce = blob.copyOfRange(0, GCM_NONCE_BYTES)
        val ct = blob.copyOfRange(GCM_NONCE_BYTES, blob.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, nonce))
        return cipher.doFinal(ct)
    }

    /** True when the wrap key already exists in Keystore. Useful to gate
     *  "first launch" vs "later launch" flows without forcing a generation. */
    fun keyExists(): Boolean {
        return try {
            val ks = KeyStore.getInstance(PROVIDER).also { it.load(null) }
            ks.containsAlias(KEY_ALIAS)
        } catch (_: Throwable) {
            false
        }
    }

    /** Wipe the wrap key. Subsequent [unwrap] calls fail; subsequent
     *  [wrap] calls regenerate. Useful on explicit local reset paths
     *  so cached blobs become permanently unreadable. */
    fun deleteKey() {
        try {
            val ks = KeyStore.getInstance(PROVIDER).also { it.load(null) }
            if (ks.containsAlias(KEY_ALIAS)) {
                ks.deleteEntry(KEY_ALIAS)
                Log.i(TAG, "wrap key deleted")
            }
        } catch (e: Throwable) {
            Log.w(TAG, "deleteKey failed: ${e.message}")
        }
    }

    private fun ensureKey(): SecretKey {
        loadKey()?.let { return it }
        return generateKey()
    }

    private fun loadKey(): SecretKey? {
        return try {
            val ks = KeyStore.getInstance(PROVIDER).also { it.load(null) }
            (ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey
        } catch (e: Throwable) {
            Log.w(TAG, "loadKey: ${e.javaClass.simpleName}: ${e.message}")
            null
        }
    }

    private fun generateKey(): SecretKey {
        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        val specBuilder = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            // Don't require user authentication. The car's head unit has no
            // user lock screen at the level that gates Keystore — requiring
            // auth would brick the app. The wrap is purely device-binding,
            // not identity-binding.
            .setUserAuthenticationRequired(false)
            // Randomized encryption: each Cipher.getInstance() with this
            // key uses a fresh random IV. We pull the IV back via
            // cipher.iv after init() — required for AES-GCM correctness.
            .setRandomizedEncryptionRequired(true)

        // On API 31+ explicitly request StrongBox if available. StrongBox is
        // a separate physical secure element (vs TEE which shares the main
        // SoC). On head units that have it, the wrap key never enters main
        // memory at all. Falls back to TEE if StrongBox is missing.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                specBuilder.setIsStrongBoxBacked(true)
            } catch (_: Throwable) {
                // Some devices throw on the setter itself if no StrongBox
                // hardware exists. Swallow — the build below either way
                // produces a hardware-backed key (TEE) or software fallback.
            }
        }

        kg.init(specBuilder.build())
        return try {
            kg.generateKey()
        } catch (e: Throwable) {
            // A StrongBox device that throws at generateKey time → retry
            // without StrongBox. Some Samsung firmwares advertise
            // StrongBox via the setter then refuse at generation.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                Log.w(TAG, "StrongBox-backed key gen failed (${e.message}), retrying TEE")
                val fallback = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
                fallback.init(
                    KeyGenParameterSpec.Builder(
                        KEY_ALIAS,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                    )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .setUserAuthenticationRequired(false)
                        .setRandomizedEncryptionRequired(true)
                        .build()
                )
                fallback.generateKey()
            } else {
                throw e
            }
        }
    }
}

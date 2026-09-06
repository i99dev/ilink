package com.i99dev.ilink.security

import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec
import javax.crypto.SecretKeyFactory

/**
 * Symmetric crypto primitives for the CarTable + unit-DEX encryption paths.
 *
 * Intentionally pure — no Android Context, no package manager — so these
 * can be unit-tested in plain JVM and re-used from both the table loader
 * and the DEX extractor.
 *
 * Existing cryptographic formats remain readable during standalone upgrades.
 */
object CryptoUtils {
    private const val PBKDF2_ITERS = 200_000
    private const val KEY_BYTES = 32 // 256-bit AES
    private const val GCM_TAG_BITS = 128
    private const val GCM_NONCE_BYTES = 12

    /**
     * Compatibility key derived from the public signing-certificate digest
     * and public salt. Anyone with those inputs can derive the same bytes;
     * this neither requires the private release key nor keeps tables secret.
     * Fresh standalone assets ship in plaintext. Keep this format unchanged
     * for retained encrypted resources; actual APK identity is verified by
     * Android signatures and the separate signer checks.
     */
    fun deriveReleaseKey(
        signerSha: ByteArray,
        salt: ByteArray,
    ): SecretKey {
        val password = hexCharsOf(signerSha)
        val spec = PBEKeySpec(password, salt, PBKDF2_ITERS, KEY_BYTES * 8)
        val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        val keyBytes = factory.generateSecret(spec).encoded
        return SecretKeySpec(keyBytes, "AES")
    }

    /**
     * Derive a 256-bit AES key bound to (deviceId || signerSha || salt).
     * Retained format for device-local logs/caches. These inputs are not a
     * random secret: knowing the device ID and public certificate/salt is
     * sufficient to reconstruct the key. Wrapping a stored copy does not
     * prevent that derivation. Do not use this as a credential vault.
     */
    fun deriveDeviceKey(
        deviceId: ByteArray,
        signerSha: ByteArray,
        salt: ByteArray,
    ): SecretKey {
        val password = buildPasswordChars(deviceId, signerSha)
        val spec = PBEKeySpec(password, salt, PBKDF2_ITERS, KEY_BYTES * 8)
        val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        val keyBytes = factory.generateSecret(spec).encoded
        return SecretKeySpec(keyBytes, "AES")
    }

    /**
     * v2 table key — HKDF-SHA-256 over `serverSecret || signerSha`.
     * Read compatibility for existing locally cached v2 tables. The stored
     * per-install secret and original signer bytes remain unchanged. No
     * remote provisioning or download path is required by this reader.
     *
     * `info` is the HKDF context-binding parameter — pass a constant
     * like `"car_table.v2"` so the same secret can produce
     * domain-separated keys for different blobs.
     *
     * Why HKDF here, not PBKDF2: the inputs are already high-entropy
     * (32B random + 32B SHA-256). PBKDF2 work-factoring buys nothing
     * over HKDF when there's no password to stretch.
     */
    fun deriveTableKeyV2(
        serverSecret: ByteArray,
        signerSha: ByteArray,
        salt: ByteArray,
        info: String,
    ): SecretKey {
        require(serverSecret.size >= 16) { "serverSecret too short" }
        require(signerSha.isNotEmpty()) { "signerSha empty" }
        val ikm = serverSecret + signerSha
        val prk = hkdfExtract(salt, ikm)
        val okm = hkdfExpand(prk, info.toByteArray(Charsets.UTF_8), KEY_BYTES)
        return SecretKeySpec(okm, "AES")
    }

    // RFC 5869 HKDF-Extract. Empty salt falls back to a zeroed
    // HashLen=32 array per RFC 5869 §2.2.
    private fun hkdfExtract(salt: ByteArray, ikm: ByteArray): ByteArray {
        val effectiveSalt = if (salt.isEmpty()) ByteArray(32) else salt
        val mac = javax.crypto.Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(effectiveSalt, "HmacSHA256"))
        return mac.doFinal(ikm)
    }

    // RFC 5869 HKDF-Expand. `length` capped at 32B (single hash block,
    // sufficient for AES-256). The expansion loop is omitted because we
    // never ask for more than one block; if a future call needs more,
    // implement N counter rounds per RFC 5869 §2.3.
    private fun hkdfExpand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..32) { "HKDF-Expand length $length out of range" }
        val mac = javax.crypto.Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        mac.update(info)
        mac.update(0x01.toByte())
        return mac.doFinal().copyOf(length)
    }

    /**
     * Encrypt plaintext with AES-256-GCM. Output layout: `nonce(12) || ct || tag(16)`.
     * Nonce MUST NOT be reused with the same key; caller supplies a fresh
     * random nonce per call.
     */
    fun encryptAesGcm(plaintext: ByteArray, key: SecretKey, nonce: ByteArray): ByteArray {
        require(nonce.size == GCM_NONCE_BYTES) {
            "nonce must be $GCM_NONCE_BYTES bytes, got ${nonce.size}"
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, nonce))
        val ct = cipher.doFinal(plaintext)
        return nonce + ct
    }

    /**
     * Decrypt output of [encryptAesGcm]. Throws `AEADBadTagException` (or a
     * subclass) on tamper — callers should let the exception propagate so
     * the loader fails closed rather than serving attacker-supplied bytes.
     */
    fun decryptAesGcm(blob: ByteArray, key: SecretKey): ByteArray {
        require(blob.size > GCM_NONCE_BYTES + (GCM_TAG_BITS / 8)) {
            "blob too short to contain nonce + tag"
        }
        val nonce = blob.copyOfRange(0, GCM_NONCE_BYTES)
        val payload = blob.copyOfRange(GCM_NONCE_BYTES, blob.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, nonce))
        return cipher.doFinal(payload)
    }

    /** SHA-256 convenience used by the integrity gate on unit DEX files. */
    fun sha256(bytes: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(bytes)

    /**
     * Concatenate (deviceId || '.' || signerSha) as hex chars for PBKDF2.
     * Hex-encoded so the char-based PBEKeySpec input is JVM-charset-
     * agnostic. Used by [deriveDeviceKey] only.
     */
    private fun buildPasswordChars(deviceId: ByteArray, signerSha: ByteArray): CharArray {
        val sb = StringBuilder(deviceId.size * 2 + signerSha.size * 2 + 1)
        for (b in deviceId) sb.append(String.format("%02x", b))
        sb.append('.')
        for (b in signerSha) sb.append(String.format("%02x", b))
        val out = CharArray(sb.length)
        for (i in out.indices) out[i] = sb[i]
        return out
    }

    /** Hex-encode bytes into a CharArray for release-key PBKDF2 input. */
    private fun hexCharsOf(bytes: ByteArray): CharArray {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) sb.append(String.format("%02x", b))
        val out = CharArray(sb.length)
        for (i in out.indices) out[i] = sb[i]
        return out
    }
}

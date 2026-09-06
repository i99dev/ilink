package com.i99dev.ilink.security

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

/**
 * Cross-language anti-drift keystone for the v2 dispatch-table crypto.
 *
 * The SAME frozen vector is pinned on the backend
 * (`tests/dispatch_table/test_interop_golden.py`). The backend SEALS it;
 * this side must DERIVE the same key and DECRYPT the same blob back to
 * the plaintext. If either implementation changes salt / info / IKM order
 * / HKDF / AEAD in a contract-breaking way, the frozen bytes stop
 * matching and this fails BEFORE a real car fails to decrypt its table.
 *
 * Do NOT "fix" a failure by re-baking the constants — fix the impl that
 * drifted (or, for a deliberate contract change, bump both sides + the
 * server_secret_rotation_id and regenerate the vector knowingly).
 */
class DispatchTableContractTest {
    private val serverSecret = ByteArray(32) { it.toByte() } // 00 01 … 1f
    private val signerSha = ByteArray(32) { 0xAA.toByte() }
    private val salt = "byd-dash-v1".toByteArray(Charsets.UTF_8)

    // Frozen on the backend golden — regenerated only on a deliberate bump.
    private val carKeyHex =
        "cd008fd39cb650d61e0f9df8747defab864ee046a755bff931ea15abc678ed2a"
    private val miniAppKeyHex =
        "6dbcf772d6e85276f0526333c6367b785d3360647101cf5cceb7a528ad325882"
    private val carBlobHex =
        "101112131415161718191a1be67b78281d844692c694fa91699719fe4af6d7" +
            "69392d3000182ad5250152850afe7820"
    private val plaintext = "car-table-v2-golden"

    @Test
    fun deriveTableKeyV2_matches_backend_golden() {
        val key = CryptoUtils.deriveTableKeyV2(serverSecret, signerSha, salt, "car_table.v2")
        assertEquals(carKeyHex, key.encoded.toHex())
    }

    @Test
    fun decrypts_backend_sealed_golden_blob() {
        val key = CryptoUtils.deriveTableKeyV2(serverSecret, signerSha, salt, "car_table.v2")
        val out = CryptoUtils.decryptAesGcm(carBlobHex.hexToBytes(), key)
        assertEquals(plaintext, String(out, Charsets.UTF_8))
    }

    @Test
    fun info_domain_separates_car_from_mini_app() {
        val car = CryptoUtils.deriveTableKeyV2(serverSecret, signerSha, salt, "car_table.v2")
        val mini = CryptoUtils.deriveTableKeyV2(serverSecret, signerSha, salt, "mini_app_table.v2")
        assertEquals(miniAppKeyHex, mini.encoded.toHex())
        assertNotEquals(car.encoded.toHex(), mini.encoded.toHex())
    }

    private fun ByteArray.toHex(): String =
        joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    private fun String.hexToBytes(): ByteArray =
        chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}

package com.i99dev.ilink.adb

import android.content.Context
import android.util.Base64
import android.util.Log
import java.io.File
import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.security.interfaces.RSAPublicKey
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec

/**
 * RSA key management for ADB auth. Ported from car-app/adb/AdbCrypto.kt.
 * Keys live in the app's private `files/.adb_keys/` directory.
 */
object AdbCrypto {
    private const val TAG = "AdbCrypto"
    private const val KEY_DIR = ".adb_keys"
    private const val PRIV_FILE = "adbkey"
    private const val PUB_FILE = "adbkey.pub"
    private const val TRUST_FILE = "adb_trusted"
    private const val KEY_TAG = "dash"

    private fun keyDir(ctx: Context): File =
        File(ctx.filesDir, KEY_DIR).also { it.mkdirs() }

    /** Reuse the device's private stored keys, or generate a new per-install keypair.
     * No shared fleet credential is bundled or read from the APK. */
    fun loadOrCreateKeyPair(ctx: Context): Pair<PrivateKey, PublicKey> {
        val dir = keyDir(ctx)
        val privFile = File(dir, PRIV_FILE)
        val pubFile = File(dir, PUB_FILE)
        if (privFile.exists() && pubFile.exists() && privFile.length() > 0) {
            try {
                val factory = KeyFactory.getInstance("RSA")
                val privKey = factory.generatePrivate(
                    PKCS8EncodedKeySpec(Base64.decode(privFile.readText(), Base64.NO_WRAP))
                )
                val pubKey = factory.generatePublic(
                    X509EncodedKeySpec(Base64.decode(pubFile.readText(), Base64.NO_WRAP))
                )
                return Pair(privKey, pubKey)
            } catch (e: Exception) {
                Log.w(TAG, "re-generating keys: ${e.message}")
                File(dir, TRUST_FILE).delete()
            }
        }
        return generateKeyPair(privFile, pubFile)
    }

    private fun generateKeyPair(privFile: File, pubFile: File): Pair<PrivateKey, PublicKey> {
        privFile.parentFile?.mkdirs()
        val kpg = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }
        val kp = kpg.generateKeyPair()
        privFile.writeText(Base64.encodeToString(kp.private.encoded, Base64.NO_WRAP))
        pubFile.writeText(Base64.encodeToString(kp.public.encoded, Base64.NO_WRAP))
        if (privFile.length() == 0L)
            throw RuntimeException("failed to write ${privFile.absolutePath}")
        return Pair(kp.private, kp.public)
    }

    fun sign(privateKey: PrivateKey, data: ByteArray): ByteArray {
        val sig = Signature.getInstance("SHA1withRSA")
        sig.initSign(privateKey)
        sig.update(data)
        return sig.sign()
    }

    /**
     * Serialize public key to ADB wire format — base64(struct) + " " + tag + "\0".
     * Matches AOSP android_pubkey.cpp.
     */
    fun adbPublicKeyBytes(pub: PublicKey): ByteArray {
        val rsaPub = pub as RSAPublicKey
        val n = rsaPub.modulus
        val e = rsaPub.publicExponent
        val numWords = 64
        val r32 = BigInteger.ONE.shiftLeft(32)
        val n0inv = r32.subtract(n.mod(r32).modInverse(r32)).toInt()
        val r = BigInteger.ONE.shiftLeft(2048)
        val rr = r.modPow(BigInteger.valueOf(2), n)

        val buf = ByteBuffer.allocate(4 + 4 + numWords * 4 + numWords * 4 + 4)
            .order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(numWords)
        buf.putInt(n0inv)
        putBigIntLE(buf, n, numWords)
        putBigIntLE(buf, rr, numWords)
        buf.putInt(e.toInt())
        val b64 = Base64.encodeToString(buf.array(), Base64.NO_WRAP)
        return ("$b64 $KEY_TAG\u0000").toByteArray()
    }

    private fun putBigIntLE(buf: ByteBuffer, value: BigInteger, numWords: Int) {
        val bytes = value.toByteArray()
        for (i in 0 until numWords) {
            var word = 0
            for (j in 0 until 4) {
                val byteIndex = bytes.size - 1 - (i * 4 + j)
                if (byteIndex in bytes.indices) {
                    word = word or ((bytes[byteIndex].toInt() and 0xFF) shl (j * 8))
                }
            }
            buf.putInt(word)
        }
    }

    fun markTrusted(ctx: Context) {
        File(keyDir(ctx), TRUST_FILE).writeText("trusted")
    }
}

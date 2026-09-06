package com.i99dev.ilink.clusterpatch

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.android.apksig.ApkSigner
import java.io.File
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.cert.X509Certificate
import java.util.Date
import javax.security.auth.x500.X500Principal

/** Port used by the file patcher; tests can provide a disposable test identity. */
fun interface ApkSigningProvider {
    fun sign(input: File, output: File, minSdkVersion: Int)
}

/** Device-local, non-exportable signing identity. Never loads a bundled private key.
 * The production patcher runs as shell UID; its Keystore namespace owns this key.
 * The Flutter host queries only its certificate fingerprint from that same process.
 */
object PatchSigner : ApkSigningProvider {
    private const val ALIAS = "ilink.cluster.patch.local.v1"

    @Synchronized private fun signingEntry(): KeyStore.PrivateKeyEntry {
        // app_process does not inherit Zygote's provider preload. Install the
        // platform provider when absent, using the platform's own registration.
        if (java.security.Security.getProvider("AndroidKeyStore") == null) {
            val provider = if (android.os.Build.VERSION.SDK_INT >= 31) {
                "android.security.keystore2.AndroidKeyStoreProvider"
            } else {
                "android.security.keystore.AndroidKeyStoreProvider"
            }
            Class.forName(provider).getMethod("install").invoke(null)
        }
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!store.containsAlias(ALIAS)) {
            val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore")
            generator.initialize(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setKeySize(2048)
                    .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA512)
                    .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1, KeyProperties.SIGNATURE_PADDING_RSA_PSS)
                    .setCertificateSubject(X500Principal("CN=ilink local cluster patch"))
                    .setCertificateSerialNumber(BigInteger.ONE)
                    .setCertificateNotBefore(Date(0))
                    .setCertificateNotAfter(Date(4102444800000L))
                    .setUserAuthenticationRequired(false)
                    .build(),
            )
            generator.generateKeyPair()
        }
        return store.getEntry(ALIAS, null) as? KeyStore.PrivateKeyEntry
            ?: error("Local cluster-patch signing identity unavailable")
    }

    fun certificateSha256(): String = MessageDigest.getInstance("SHA-256")
        .digest(signingEntry().certificate.encoded)
        .joinToString("") { "%02x".format(it.toInt() and 255) }

    override fun sign(input: File, output: File, minSdkVersion: Int) {
        val entry = signingEntry()
        signWithIdentity(input, output, minSdkVersion, entry.privateKey,
            entry.certificateChain.map { it as X509Certificate })
    }

    /** Shared APK signing implementation; supplied identities never become classpath assets. */
    internal fun signWithIdentity(input: File, output: File, minSdkVersion: Int,
        key: PrivateKey, certificates: List<X509Certificate>) {
        val config = ApkSigner.SignerConfig.Builder("CERT", key, certificates).build()
        ApkSigner.Builder(listOf(config))
            .setInputApk(input)
            .setOutputApk(output)
            .setMinSdkVersion(minSdkVersion)
            .setV1SigningEnabled(false)
            .setV2SigningEnabled(true)
            .build()
            .sign()
    }
}

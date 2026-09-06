package com.i99dev.ilink.security

import android.content.Context
import android.util.Log
import java.io.File
import javax.crypto.AEADBadTagException

/**
 * Shared load + decrypt for the per-install encrypted dispatch tables
 * (`car_table`, `mini_app_table`). Both use the *exact* same v2 scheme
 * (filesDir, HKDF over `server_secret || signer_sha`) — only the proto
 * schema differs — so the decrypt lives here in ONE place and each
 * `*TableSource` supplies just its file names + its own proto decode.
 *
 * Returns **plaintext bytes**, never a parsed object, so the schema-specific
 * decode (textproto vs binary) stays in the caller. A crypto change happens
 * in one audited spot.
 *
 * Compatibility reader only. Fresh installations use LocalTableLoader and
 * do not need this cache or a server-issued secret.
 */
object EncryptedTableLoader {

    /**
     * v2 — `<filesDir>/<v2FileName>` keyed off the per-install server
     * secret (HKDF over `server_secret || signer_sha`, info=[v2Info]).
     * Strongest confidentiality: the APK alone can't derive the key.
     * Returns null when no legacy secret exists, the file is
     * absent, or decrypt/auth fails. [tag] scopes the log line.
     */
    fun v2PlaintextOrNull(
        context: Context,
        v2FileName: String,
        v2Info: String,
        tag: String,
    ): ByteArray? {
        // Not-yet-provisioned states are NOT failures — leave any cached
        // blob untouched and let the next sync deliver/refresh it.
        val v2File = File(context.filesDir, v2FileName)
        return try {
            if (!v2File.exists()) return null
            val secret = LegacyTableSecretStore.get(context) ?: return null
            require(v2File.length() <= 2 * 1024 * 1024) { "Cached table exceeds size limit" }
            val signerSha = DeviceKeyMaterial.fromContext(context).signerSha
            val salt = DeviceKeyMaterial.BUILD_SALT
            val key = CryptoUtils.deriveTableKeyV2(secret, signerSha, salt, v2Info)
            val plaintext = CryptoUtils.decryptAesGcm(v2File.readBytes(), key)
            Log.i(tag, "loaded v2 table from $v2FileName")
            plaintext
        } catch (e: AEADBadTagException) {
            // Preserve old user data. Clearing only the ETag allows an opted-in
            // local diagnostics to inspect this cache; offline boot uses the APK table.
            Log.w(tag, "v2 decrypt bad-tag — using bundled table; retaining $v2FileName")
            runCatching {
                File(context.filesDir, v2FileName.removeSuffix(".pb.enc") + ".etag").delete()
            }
            null
        } catch (t: Throwable) {
            // Transient (IO, OOM, …) — keep the blob; the next boot retries.
            Log.w(tag, "v2 load failed: ${t.javaClass.simpleName}: ${t.message}")
            null
        }
    }
}

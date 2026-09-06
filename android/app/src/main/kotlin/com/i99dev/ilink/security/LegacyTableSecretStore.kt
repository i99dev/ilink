package com.i99dev.ilink.security

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Compatibility storage for an existing installation's legacy table secret.
 * Preserves the wrapped value needed to read cached v2 dispatch tables.
 * The standalone app has no pairing service or new remote secret issuance.
 * Wrapping uses Android Keystore; hardware backing is device-dependent.
 */
object LegacyTableSecretStore {
    private const val TAG = "LegacyTableSecretStore"
    private const val FILE_NAME = "server-secret.bin"

    /**
     * Retrieve the persisted secret. Returns null when (a) never
     * provisioned, (b) Keystore key was wiped (factory reset, app data
     * cleared), or (c) the wrapped blob is corrupted.
     *
     * Callers MUST treat null as "no per-install confidentiality
     * available" and use the public bundled table.
     */
    fun get(context: Context): ByteArray? {
        val f = file(context)
        if (!f.exists()) return null
        return try {
            KeystoreWrap.unwrap(f.readBytes())
        } catch (e: Throwable) {
            Log.w(TAG, "get failed: ${e.javaClass.simpleName}: ${e.message}")
            null
        }
    }

    /**
     * Wipe both the wrapped blob on disk AND the Keystore-resident
     * wrap key. After this, the previously-stored secret is
     * permanently unrecoverable (the wrapped blob is encrypted under
     * the old wrap key which no longer exists in Keystore).
     *
     * Use on explicit local reset paths. Idempotent.
     */
    fun clear(context: Context) {
        file(context).delete()
        KeystoreWrap.deleteKey()
        Log.i(TAG, "server secret cleared")
    }

    private fun file(context: Context): File =
        File(context.filesDir, FILE_NAME)
}

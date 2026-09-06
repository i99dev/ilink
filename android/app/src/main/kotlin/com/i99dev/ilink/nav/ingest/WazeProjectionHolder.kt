package com.i99dev.ilink.nav.ingest

import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.util.Log

/**
 * Holds the MediaProjection consent token (resultCode + data Intent) and the live
 * [MediaProjection] in-process. The consent activity sets the token once; the
 * capture service builds/rebuilds the projection from it on (re)start. No
 * persistence — a projection token can't survive process death (and on API 34+ is
 * single-use per projection), so after a cold start the user re-grants. Mirrors the
 * reference's in-memory projection holder. Thread-safe.
 */
object WazeProjectionHolder {
    private const val TAG = "WazeProjection"

    @Volatile private var resultCode: Int = 0
    @Volatile private var data: Intent? = null
    @Volatile private var active: MediaProjection? = null

    /** True once consent has been granted this process (token present). */
    val hasConsent: Boolean get() = data != null

    @Synchronized
    fun setToken(resultCode: Int, data: Intent) {
        this.resultCode = resultCode
        this.data = Intent(data) // defensive copy
    }

    /**
     * The cached live projection, or a fresh one built from the stored token. null
     * when there's no token yet (consent needed) or the build failed. The CALLER
     * owns registering a stop callback + lifecycle (the capture service does).
     */
    @Synchronized
    fun acquire(ctx: Context): MediaProjection? {
        active?.let { return it }
        val token = data ?: return null
        return try {
            val mgr = ctx.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            mgr.getMediaProjection(resultCode, token).also { active = it }
        } catch (t: Throwable) {
            Log.w(TAG, "getMediaProjection failed: ${t.message}")
            // A consumed/expired token can't be reused — force a re-prompt next time.
            data = null
            null
        }
    }

    /** Called when the projection stops (user revoked, or service torn down). */
    @Synchronized
    fun onProjectionStopped() {
        active = null
    }

    /** Full reset — drops the token too (next start re-prompts). */
    @Synchronized
    fun clear() {
        active = null
        data = null
        resultCode = 0
    }
}

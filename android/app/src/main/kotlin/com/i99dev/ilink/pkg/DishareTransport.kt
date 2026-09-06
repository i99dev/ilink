package com.i99dev.ilink.pkg

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Cast a target package to a BYD secondary surface (passenger
 * panel, cluster centre, cluster top-right) via the **DiShare**
 * direct-API path. Discovered + verified non-root path on Di5.0
 * trims (Leopard 5 / Leopard 5 Ultra) where `am start --display N`
 * is silently dropped by stricter access control on the XDJA /
 * BYD-container virtual displays.
 *
 * Recipe (verified against a reference DiShare launcher, which is
 * also where the quickShare opcode was found):
 *
 *   1. Bind `com.byd.dishare/.api.DiShareApiService`. No permission
 *      check on `onBind` — any app can connect.
 *   2. op=1 `register(client, packageName)` — DiShare locks its
 *      mirror source to the target package.
 *   3. op=11 `setVideoSize(w, h)` — declares the mirror's native
 *      shape. Pinned to 1920×720 (passenger panel native).
 *   4. op=9 `setGestureShareEnabled(true)` — arms DiShare's commit
 *      machinery. Required even though we don't dispatch a gesture.
 *   5. op=8 `quickShare(deviceTag)` — direct API commit to the
 *      named surface (`ivi` / `fse` / `cluster_c` / `cluster_tr`).
 *      DiShare routes pixels without waiting for an input event.
 *
 * Returns a [LaunchResult]-shaped map matching the rest of the
 * `pkg` family wire shape so `PackagePlatformPlugin.handleLaunch`
 * can forward it without re-shape.
 *
 * Predecessor (deleted 2026-05-15): the original implementation
 * used a synthetic 2-finger swipe injected via `MultiTouchInjector`
 * over loopback ADB to commit the share. That path worked but was
 * ~1.5s end-to-end, visibly flashed the target app on the IVI
 * during the foreground step, and required the AdbShellBridge to
 * be authorized. The verified quickShare op replaced
 * all of that with one binder transaction.
 */
class DishareTransport(private val applicationContext: Context) {

    /** Long-lived API-service session, retained across casts. DiShare
     *  ties the active mirror to whichever client binder armed it
     *  with `setGestureShareEnabled(true)` — if we unbind right after
     *  the cast (the obvious finally-block cleanup), DiShare sees
     *  the binder die and tears the share down ~2s later. Keeping
     *  the session bound for the lifetime of the host process keeps
     *  the cast alive until the user dismisses it. The session is
     *  re-bound transparently if DiShare or the system kills it. */
    private var liveApiSession: DishareSession? = null

    /** Package name of the app currently mirrored on the active
     *  surface via this transport's session, or null when no cast
     *  is live. Lets [fastCast] short-circuit when the user
     *  re-launches the same app onto the same surface — re-running
     *  register + setVideoSize + setGestureShare + quickShare is
     *  cheap (~50ms warm) but pointless when nothing's changed.
     *  Cleared on a failed cast so the next attempt re-runs the
     *  full sequence. */
    private var currentMirrorPackage: String? = null

    /** Device tag of the surface the live session is currently
     *  routing to, paired with [currentMirrorPackage]. Tracked
     *  separately because DiShare's per-client share state is
     *  single-slot — switching from `fse` to `cluster_tr` always
     *  requires re-issuing `quickShare`, even if the package is
     *  unchanged. */
    private var currentMirrorTag: String? = null

    /**
     * Direct-commit DiShare cast: routes [packageName] to the
     * physical surface identified by [deviceTag] (one of the
     * `DEVICE_*` constants on this class's companion).
     *
     * Implements the verified recipe — five binder
     * transactions, no synthetic input injection, no IVI
     * foregrounding:
     *
     *   1. `bindApi()` to DiShare's API service.
     *   2. `register(packageName)` — locks DiShare's mirror source
     *      to the target package.
     *   3. `setVideoSize(VIDEO_W, VIDEO_H)` — declares the mirror's
     *      native shape so DiShare doesn't downscale a 2560-wide IVI
     *      capture to the passenger panel.
     *   4. `setGestureShare(true)` — arms DiShare's commit machinery.
     *      (Required even though we don't dispatch a gesture; the
     *      service treats this as the "client is ready" handshake.)
     *   5. `quickShare(deviceTag)` — direct API commit to the named
     *      surface. DiShare routes pixels without waiting for a
     *      gesture detector.
     *
     * The wire shape was reverse-engineered from a reference
     * DiShare launcher's RouteEngine (op=8 / op=11).
     *
     * Returns `{ok, path, error}` with `path="dishare-quickshare"`
     * on success or `path="dishare-denied"` with a typed error
     * string when any step fails. The session is kept bound on
     * success so a follow-up call to the same `(packageName,
     * deviceTag)` short-circuits and re-uses the warm binder.
     *
     * Caller is responsible for running this off the main thread —
     * `bindApi()` blocks up to [BIND_TIMEOUT_MS] on the service
     * connection callback.
     */
    fun fastCast(packageName: String, deviceTag: String): Map<String, Any?> {
        // Warm-binder short-circuit: same package, same target,
        // session still alive. Saves a full 5-transaction round-trip
        // for the common "user re-taps the same app on the same
        // panel" case. We deliberately re-issue the cast when the
        // target tag differs because DiShare's per-client share
        // state is single-slot — switching surfaces always needs a
        // fresh quickShare.
        if (currentMirrorPackage == packageName &&
            currentMirrorTag == deviceTag &&
            liveApiSession?.isAlive() == true
        ) {
            Log.i(TAG, "fastCast short-circuit: $packageName already on $deviceTag")
            return result(true, "dishare-quickshare-cached", null)
        }
        if (liveApiSession?.isAlive() == false) {
            liveApiSession?.close()
            liveApiSession = null
            currentMirrorPackage = null
            currentMirrorTag = null
        }
        // Pre-flight: DiShare service must be present. Same check
        // as [cast]; the install probe is cheap and gives a typed
        // error instead of letting the bind fail opaquely.
        if (!isPackageInstalled(DISHARE_PKG)) {
            return result(false, "dishare-denied", "dishare_not_installed")
        }
        val session = liveApiSession ?: DishareSession().also { liveApiSession = it }
        var castCommitted = false
        try {
            Log.i(TAG, "fastCast start pkg=$packageName tag=$deviceTag")
            if (!session.bindApi()) {
                return result(false, "dishare-denied", "bind_failed")
            }
            Log.i(TAG, "fastCast step1 bind ok")
            if (!session.register(packageName)) {
                return result(false, "dishare-denied", "register_failed")
            }
            Log.i(TAG, "fastCast step2 register ok")
            if (!session.setVideoSize(VIDEO_W, VIDEO_H)) {
                return result(false, "dishare-denied", "video_size_failed")
            }
            Log.i(TAG, "fastCast step3 video_size ok ${VIDEO_W}x${VIDEO_H}")
            if (!session.setGestureShareEnabled(true)) {
                return result(false, "dishare-denied", "arm_failed")
            }
            Log.i(TAG, "fastCast step4 arm ok")
            if (!session.quickShare(deviceTag)) {
                return result(false, "dishare-denied", "quick_share_failed")
            }
            Log.i(TAG, "fastCast step5 quickShare ok tag=$deviceTag")
            castCommitted = true
            currentMirrorPackage = packageName
            currentMirrorTag = deviceTag
            return result(true, "dishare-quickshare", null)
        } finally {
            if (!castCommitted) {
                session.close()
                liveApiSession = null
                currentMirrorPackage = null
                currentMirrorTag = null
            }
        }
    }

    private fun isPackageInstalled(pkg: String): Boolean = try {
        applicationContext.packageManager.getApplicationInfo(pkg, 0)
        true
    } catch (_: Throwable) {
        false
    }

    private fun result(ok: Boolean, path: String, error: String?): Map<String, Any?> =
        mapOf("ok" to ok, "path" to path, "error" to error)

    /**
     * One-shot bind + transact + unbind helper. Holds the binder for
     * the duration of a single cast and releases on close. Not
     * thread-safe — caller serialises through [adbExecutor] in
     * [PackagePlatformPlugin].
     */
    private inner class DishareSession {
        private var apiBinder: IBinder? = null
        private var apiConnection: ServiceConnection? = null
        private val readyLatch = CountDownLatch(1)
        private val bindOk = AtomicBoolean(false)

        // Client callback binder DiShare calls back on. Wire shape is
        // a faithful port of a WORKING reference app's DiShare
        // client callback — verified to drive DiShare correctly on
        // this exact car.
        //
        // The previous impl returned `true` for EVERY transaction and
        // never answered `INTERFACE_TRANSACTION`, so DiShare's client-
        // interface verification failed and it silently refused to
        // commit the mirror even though register/quickShare
        // "succeeded" (the "register ok but never casts" bug). The
        // contract DiShare actually expects:
        //   * code == 1 → mirror-state notify: drain the token, read
        //     the int state, ack with `true`.
        //   * code == INTERFACE_TRANSACTION → write the client
        //     interface descriptor back (this is the bit that was
        //     missing — it's how DiShare validates the callback).
        //   * anything else → defer to Binder's default handling.
        private val clientBinder: Binder = object : Binder() {
            init { attachInterface(null, CLIENT_IFACE) }
            override fun onTransact(
                code: Int,
                data: Parcel,
                reply: Parcel?,
                flags: Int,
            ): Boolean {
                if (code == 1) {
                    runCatching {
                        data.enforceInterface(CLIENT_IFACE)
                        val state = data.readInt()
                        Log.i(TAG, "client callback state=$state")
                    }
                    return true
                }
                if (code == IBinder.INTERFACE_TRANSACTION) {
                    reply?.writeString(CLIENT_IFACE)
                    return true
                }
                return super.onTransact(code, data, reply, flags)
            }
        }

        fun bindApi(): Boolean {
            // Idempotent: a session reused across casts re-enters here
            // with a live binder. Returning early avoids stacking
            // bindService refcounts (Android increments on every call,
            // and we'd be left with one unbind per call to balance).
            if (apiBinder != null && bindOk.get()) return true
            val intent = Intent(SERVICE_ACTION).setPackage(DISHARE_PKG)
            val conn = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName, service: IBinder) {
                    apiBinder = service
                    bindOk.set(true)
                    readyLatch.countDown()
                }
                override fun onServiceDisconnected(name: ComponentName) {
                    apiBinder = null
                    bindOk.set(false)
                }
            }
            apiConnection = conn
            // bindService MUST be called from a context with a real
            // looper. ApplicationContext qualifies; fail loud if not.
            val accepted = applicationContext.bindService(intent, conn, Context.BIND_AUTO_CREATE)
            if (!accepted) return false
            return readyLatch.await(BIND_TIMEOUT_MS, TimeUnit.MILLISECONDS) && bindOk.get()
        }

        fun register(targetPkg: String): Boolean = transact(OP_REGISTER) { p ->
            p.writeStrongBinder(clientBinder)
            p.writeString(targetPkg)
        }

        fun setGestureShareEnabled(enabled: Boolean): Boolean =
            transact(OP_SET_GESTURE_SHARE_ENABLED) { p ->
                p.writeStrongBinder(clientBinder)
                p.writeInt(if (enabled) 1 else 0)
            }

        /** op=11 setVideoSize(width, height). DiShare keeps a per-
         *  client video-dimension hint that influences how it sizes
         *  the mirror stream to the target surface. The reference
         *  launcher pins 1920×720 for every cast regardless of the
         *  IVI's actual panel size — that's the *passenger panel's*
         *  native shape, not the IVI's, so passing it here makes the
         *  mirror render at native passenger resolution instead of
         *  the framework scaling a 2560-wide IVI capture down. */
        fun setVideoSize(w: Int, h: Int): Boolean =
            transact(OP_SET_VIDEO_SIZE) { p ->
                p.writeStrongBinder(clientBinder)
                p.writeInt(w)
                p.writeInt(h)
            }

        /** op=8 quickShare(deviceTag). The entry point that commits
         *  a share without going through the 2-finger swipe
         *  gesture flow — DiShare reads the device tag (`ivi` /
         *  `fse` / `cluster_c` / `cluster_tr`) and routes the
         *  mirror to that physical surface directly.
         *
         *  Opcode + parcel shape verified against a reference
         *  DiShare launcher's `DiShareCore.quickShare`.
         *  Returns the service's boolean reply via the shared
         *  [transact] helper. */
        fun quickShare(deviceTag: String): Boolean =
            transact(OP_QUICK_SHARE) { p ->
                p.writeStrongBinder(clientBinder)
                p.writeString(deviceTag)
            }

        fun close() {
            apiConnection?.let { conn ->
                runCatching { applicationContext.unbindService(conn) }
            }
            apiConnection = null
            apiBinder = null
        }

        /**
         * Best-effort liveness check for the same-package short-
         * circuit in [cast]. Returns true only when:
         *   * Our [bindApi] callback flagged the binder up, AND
         *   * The remote DiShare process responds to a binder ping.
         *
         * The ping catches the "DiShare process died / was killed by
         * the framework" case, which a stale `bindOk` flag wouldn't
         * — Android only fires `onServiceDisconnected` when the
         * service is unbound cleanly, not on a process kill.
         *
         * NOTE: this does NOT detect "user dismissed the cast from
         * the passenger panel" — DiShare's own share-state stays
         * live in that case (binder is healthy, just the mirror
         * surface is gone). True ground-truth detection requires
         * parsing the op=1 callbacks DiShare sends to our
         * [clientBinder] — a follow-up. For v1 this catches the
         * majority case (process churn).
         */
        fun isAlive(): Boolean {
            if (!bindOk.get()) return false
            val b = apiBinder ?: return false
            return runCatching { b.pingBinder() }.getOrDefault(false)
        }

        private inline fun transact(code: Int, fill: (Parcel) -> Unit): Boolean {
            val b = apiBinder ?: return false
            val data = Parcel.obtain()
            val reply = Parcel.obtain()
            return try {
                data.writeInterfaceToken(API_IFACE)
                fill(data)
                b.transact(code, data, reply, 0)
                // Match the working reference (Shaheen DiShareCore.txn):
                // read the exception slot (a genuine service-side
                // failure throws here → caught → false) then return
                // true. DiShare does NOT write an AIDL boolean result,
                // so do NOT read one — `reply.readInt()` would consume
                // past end-of-parcel and mis-report success/failure.
                reply.readException()
                true
            } catch (t: Throwable) {
                Log.w(TAG, "DiShare transact $code failed: ${t.message}")
                false
            } finally {
                data.recycle()
                reply.recycle()
            }
        }
    }

    companion object {
        private const val TAG = "DishareTransport"

        // Service identifiers — pinned to BYD's `com.byd.dishare` APK
        // (`/system/priv-app/BydDishare/...`). The Di5.0/BYD-container
        // trims (L5, Song PLUS) carry this priv-app; if a future trim
        // renames the action or interface, capability probe will catch
        // it before mini-apps land here. (L5U is Di5.1/XDJA — it does
        // NOT use this path.)
        private const val DISHARE_PKG = "com.byd.dishare"
        private const val SERVICE_ACTION = "com.byd.dishare.api.DiShareApiService"
        private const val API_IFACE = "com.byd.dishare.api.IDiShareApiService"
        private const val CLIENT_IFACE = "com.byd.dishare.api.IDiShareApiClient"

        // Opcodes verified against a reference launcher's DiShareCore.
        private const val OP_REGISTER = 1
        // op=8 quickShare(deviceTag) — direct API commit. Bypasses
        // the gesture detector, no synthetic swipe required. See
        // [DishareSession.quickShare] for the parcel shape.
        private const val OP_QUICK_SHARE = 8
        private const val OP_SET_GESTURE_SHARE_ENABLED = 9
        // op=11 setVideoSize(w, h) — caller-declared mirror video
        // dimensions. See [DishareSession.setVideoSize].
        private const val OP_SET_VIDEO_SIZE = 11

        // ── DiShare device tags ──────────────────────────────────────
        //
        // Strings DiShare's quickShare op accepts as the target
        // physical surface. Empirical inventory from the reference
        // launcher's `Targets.<clinit>`:
        //
        //   "ivi"        displayId 0 — Main Screen
        //   "fse"        displayId 2 — FSE Co-pilot (passenger)
        //   "cluster_c"  displayId 3 — Small Panel (cluster centre)
        //   "cluster_tr" displayId 4 — Driver Dashboard (cluster TR)
        //
        // A future trim may expose additional tags; until empirically
        // verified, callers should restrict themselves to this set.
        const val DEVICE_IVI = "ivi"
        const val DEVICE_FSE = "fse"
        const val DEVICE_CLUSTER_CENTER = "cluster_c"
        const val DEVICE_CLUSTER_TOPRIGHT = "cluster_tr"

        // Numeric displayIds the Di5.0 BYD-container topology assigns
        // to each device tag. The L5 / Song PLUS BYD-container layout;
        // if a future trim re-shuffles them, [DeviceTagResolver]
        // handles that without the dispatcher needing to know.
        const val DISPLAY_ID_IVI = 0
        const val DISPLAY_ID_FSE = 2
        const val DISPLAY_ID_CLUSTER_CENTER = 3
        const val DISPLAY_ID_CLUSTER_TOPRIGHT = 4

        // setVideoSize hint — pinned to 1920×720 (passenger panel
        // native shape). DiShare scales the mirror stream to fit the
        // target surface, so this is a hint, not a hard constraint;
        // matching the passenger panel avoids a downscale on the most
        // common cast target (`DEVICE_FSE`).
        private const val VIDEO_W = 1920
        private const val VIDEO_H = 720

        // bind+onServiceConnected on warm DiShare is <50ms; 1.5s
        // ceiling absorbs cold-start (the framework occasionally
        // wakes the BydDishare priv-app fresh on the first transact
        // after a long idle period).
        private const val BIND_TIMEOUT_MS = 1_500L
    }
}

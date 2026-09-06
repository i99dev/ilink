package com.i99dev.ilink.nav.transport

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.Parcel
import android.util.Log
import com.i99dev.ilink.nav.domain.NavGuidance
import com.i99dev.ilink.nav.transport.someip.SomeIpVariant
import com.i99dev.ilink.nav.transport.someip.Ui7Variant
import java.util.concurrent.Executors

/**
 * ADB-FREE cluster transport: binds the BYD SOME/IP server in-process and
 * pushes the RoadInfo payload over raw binder `transact`. **Byte-for-byte**
 * the reference's `SomeIpHudStrategy` — no AIDL stub, raw IBinder.
 *
 * Wire (ground truth):
 *  - bind  : action `com.ts.car.someip.SomeIpServerService`, pkg `com.ts.car.someip.service`
 *  - start : `transact(4)` writeLong(serviceId), once per id the variant declares
 *  - stop  : `transact(5)` writeLong(serviceId), once per id the variant declares
 *  - push  : `transact(6)` writeInt(1) + writeLong(topic) + writeLong(0) + len-prefixed payload,
 *            once per event the variant returns
 *
 * **Variant seam (TASK-002):** this class owns everything Android — bind,
 * lifecycle, transact codes, the callback binder — and owns NO bytes. Which
 * service ids to start and which `(topic, payload)` events a frame becomes is
 * entirely [SomeIpVariant]'s (default [Ui7Variant], the on-car-proven 5.0UI
 * RoadInfo wire). Swapping the variant changes payload shape and nothing else;
 * adding a trim must never require editing this file.
 *
 * UNVERIFIED (M0): whether the exported service accepts a bind from a normal
 * app uid. the reference ships this path **dead** (its author defaulted to CAN-FID),
 * so treat a failed bind as expected on some trims → the controller falls back.
 * Every binder failure throws so the controller's fail-safe re-binds / falls back.
 */
class SomeIpHudTransport(
    private val context: Context,
    renderer: HudRenderer = NoopHudRenderer,
    // Default keeps every existing call site (and on-car behaviour) identical:
    // the shipped UI7 wire, fed by the same renderer as before.
    private val variant: SomeIpVariant = Ui7Variant(renderer),
) : HudTransport {

    override val name: String = "SOME_IP"

    @Volatile private var binder: IBinder? = null
    @Volatile private var bound = false
    // Set only AFTER the start transaction (TX_START) completes, so the first
    // fireEvent can't race ahead of it.
    @Volatile private var started = false

    // The service-connection callbacks (and the TX_START transact they fire)
    // MUST run off the main thread: a slow/unresponsive SomeIpServerService
    // would otherwise block the UI thread (frozen toggle / "can't activate").
    private val connExec = Executors.newSingleThreadExecutor { r -> Thread(r, "someip-conn") }

    private val conn = object : ServiceConnection {
        override fun onServiceConnected(n: ComponentName?, service: IBinder?) {
            binder = service
            // MUST register a callback before start/fire: the SomeIpServerService
            // associates the publishing client by the registered callback binder.
            // Without it the service ignores our fireEvent (the cluster shows
            // nothing).
            runCatching { registerCallback() }
                .onFailure { Log.w(TAG, "registerCallback failed: ${it.message}") }
            runCatching { startService() }
                .onSuccess { started = true }
                .onFailure { Log.w(TAG, "startService failed: ${it.message}") }
        }
        override fun onServiceDisconnected(n: ComponentName?) {
            binder = null
            started = false
        }
    }

    private fun serviceIntent() = Intent(ACTION).setPackage(PKG)

    // 5.0UI ONLY: the RoadInfo event this transport pushes is what the Di5.0/5.1
    // cluster reads. A 7.0UI cluster (Leopard 7) reads HudNaviInfoService instead
    // and ignores RoadInfo — there it must NOT be selected (HudNaviInfoTransport
    // handles 7.0UI). 5.0UI + UNKNOWN keep the legacy behaviour unchanged.
    // Pure drive-all: SOME/IP RoadInfo is driven whenever the BYD SOME/IP service
    // is present, on ANY UI. Earlier gates (UI != 7.0UI, and !Huawei) were dropped
    // after on-car proof that (a) Huawei ADS HMI clusters ignore the BYD instrument
    // HAL but DO read SOME/IP RoadInfo, and (b) 7.0UI clusters that don't read
    // RoadInfo simply ignore the push (Leopard 7 keeps rendering via CAN-FID). So
    // pushing RoadInfo is never harmful and recovers Huawei 7.0UI clusters where the
    // HAL is dead. The cluster renders it iff it subscribes to TOPIC_ROAD.
    override fun isAvailable(): Boolean =
        runCatching {
            context.packageManager.queryIntentServices(serviceIntent(), 0).isNotEmpty()
        }.getOrDefault(false)

    /** Truly linked = bound AND onServiceConnected delivered the binder. This is
     *  the make-or-break M0 signal (did the bind from app uid actually succeed). */
    override fun connected(): Boolean = bound && binder != null

    override fun start() {
        // We keep the binding for the app's lifetime (see stop()), so a re-arm
        // doesn't re-bind — it just re-starts the event stream on the existing
        // connection.
        if (bound) {
            if (binder != null && !started) {
                runCatching { startService() }.onSuccess { started = true }
            }
            return
        }
        // Application context: the binding lives for the app's lifetime (we
        // never unbind — see stop()), so it must not be tied to an Activity.
        // Executor overload (API 29+, this car is 33): deliver onServiceConnected
        // /onServiceDisconnected on connExec, NOT the main thread, so the
        // connect-time TX_START transact can't freeze the UI.
        bound = context.applicationContext
            .bindService(serviceIntent(), Context.BIND_AUTO_CREATE, connExec, conn)
        if (!bound) error("bindService($PKG) returned false")
    }

    override fun stop() {
        if (!bound) return
        // Stop the event stream but DO NOT unbind. The BYD SomeIpServerService
        // crashes with an NPE in onUnbind() (forEach over a client map with a
        // null entry) — every unbind kills the service, tears our binding out,
        // and crash-loops via onTransportError → stop → unbind. the reference never
        // hits this because it doesn't use SOME/IP at all. So we keep the
        // binding alive (the OS reclaims it on process death) and only stop
        // pushing; re-arm reuses it. started=false so the next arm re-issues
        // TX_START before pushing.
        runCatching { stopService() }
        started = false
    }

    override fun push(frame: NavGuidance, counter: Int) {
        // Benign race (mirrors clear()): a concurrent onServiceDisconnected may null
        // the binder. Drop the frame silently — the binding is BIND_AUTO_CREATE and
        // reconnects on its own; throwing here would needlessly tear the transport
        // down and fall back to CAN-FID for a transient blip.
        val b = binder ?: return
        // Service connected but TX_START not done yet — drop this frame rather
        // than racing fireEvent ahead of start (the cluster won't render anyway).
        if (!started) return
        // A binder present but no longer ALIVE is a genuine death (service process
        // gone) — surface it so the controller fails over to CAN-FID. (A death
        // between this check and the transact still throws from fireEvent → same
        // failover path, exactly as before.)
        if (!b.isBinderAlive) error("SOME/IP binder dead")
        // Fire every event the variant produced, in order. Today that is exactly
        // one (UI7 RoadInfo), so this is the same single transact as before; a
        // multi-event variant fans out here without touching push()'s contract.
        // Failures propagate (as before) so the controller can fail over.
        for ((topic, payload) in variant.buildEvents(frame, counter)) {
            fireEvent(b, topic, payload)
        }
    }

    /** Clear = the variant's "nothing to show" events (UI7: a blank RoadInfo)
     *  while staying bound. Best-effort, exactly as before. */
    override fun clear() {
        val b = binder ?: return
        for ((topic, payload) in variant.buildClearEvents()) {
            runCatching { fireEvent(b, topic, payload) }
        }
    }

    // --- raw binder ops (exact transact codes / args) ---

    private fun fireEvent(b: IBinder, topic: Long, payload: ByteArray) {
        val d = Parcel.obtain(); val r = Parcel.obtain()
        try {
            d.writeInterfaceToken(DESCRIPTOR)
            d.writeInt(1)
            d.writeLong(topic)
            d.writeLong(0)
            d.writeInt(payload.size)
            d.writeByteArray(payload)
            b.transact(TX_FIRE_EVENT, d, r, 0)
            r.readException()
        } finally {
            r.recycle(); d.recycle()
        }
    }

    /** ISomeIpCallback the service calls back on. We only publish, so every
     *  callback is a no-op — but the binder MUST be a valid ISomeIpCallback (right
     *  descriptor + reply shape) or the service rejects/!forwards our events. */
    private val callback: IBinder = object : android.os.Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            when (code) {
                IBinder.INTERFACE_TRANSACTION -> { reply?.writeString(CALLBACK_DESCRIPTOR); return true }
                CB_ON_SOMEIP_EVENT -> { // onSomeIpEvent(SomeIpData) -> void
                    data.enforceInterface(CALLBACK_DESCRIPTOR)
                    reply?.writeNoException(); reply?.writeInt(0)
                    return true
                }
                CB_ON_HAL_STATUS -> { // onHalServiceStatus(boolean) -> void
                    data.enforceInterface(CALLBACK_DESCRIPTOR)
                    reply?.writeNoException()
                    return true
                }
                CB_ON_REQUEST -> { // onRequest(SomeIpData) -> SomeIpData (null reply)
                    data.enforceInterface(CALLBACK_DESCRIPTOR)
                    reply?.writeNoException(); reply?.writeInt(0); reply?.writeInt(0)
                    return true
                }
                else -> return super.onTransact(code, data, reply, flags)
            }
        }
    }

    private fun registerCallback() {
        val b = binder ?: return
        val d = Parcel.obtain(); val r = Parcel.obtain()
        try {
            d.writeInterfaceToken(DESCRIPTOR)
            d.writeStrongBinder(callback)
            b.transact(TX_REGISTER_CALLBACK, d, r, 0)
            r.readException()
        } finally {
            r.recycle(); d.recycle()
        }
    }

    // One transact per service id the variant declares (UI7: exactly one, so the
    // on-car sequence is unchanged). If a multi-service variant fails partway,
    // the exception propagates exactly as a single-service failure did.
    private fun startService() = variant.serviceIds.forEach { serviceCtl(TX_START, it) }
    private fun stopService() = variant.serviceIds.forEach { serviceCtl(TX_STOP, it) }

    private fun serviceCtl(code: Int, serviceId: Long) {
        val b = binder ?: return
        val d = Parcel.obtain(); val r = Parcel.obtain()
        try {
            d.writeInterfaceToken(DESCRIPTOR)
            d.writeLong(serviceId)
            b.transact(code, d, r, 0)
            r.readException()
        } finally {
            r.recycle(); d.recycle()
        }
    }

    companion object {
        private const val TAG = "SomeIpHudTransport"
        private const val ACTION = "com.ts.car.someip.SomeIpServerService"
        private const val PKG = "com.ts.car.someip.service"
        private const val DESCRIPTOR = "ts.car.someip.sdk.ISomeIpServerInterface"

        // transaction codes (ground truth — ISomeIpServerInterface AIDL order)
        private const val TX_REGISTER_CALLBACK = 1
        private const val TX_START = 4
        private const val TX_STOP = 5
        private const val TX_FIRE_EVENT = 6

        private const val CALLBACK_DESCRIPTOR = "ts.car.someip.sdk.ISomeIpCallback"
        // ISomeIpCallback AIDL transaction codes
        private const val CB_ON_SOMEIP_EVENT = 1
        private const val CB_ON_HAL_STATUS = 2
        private const val CB_ON_REQUEST = 3

        // NOTE: SERVICE_ID / TOPIC_ROAD deliberately no longer live here. They are
        // wire facts, not transport facts, and now belong to the variant
        // ([Ui7Variant.SERVICE_ID] / [Ui7Variant.TOPIC_ROAD]) — one definition,
        // pinned by NavSomeIpVariantTest's frozen goldens.
    }
}

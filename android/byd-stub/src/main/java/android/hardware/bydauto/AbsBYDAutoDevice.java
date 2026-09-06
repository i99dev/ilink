package android.hardware.bydauto;

import android.content.Context;
import android.hardware.IBYDAutoEvent;
import android.hardware.IBYDAutoListener;

/**
 * BYD framework device base class.
 *
 * Verified ABI against Dudu Launcher smali under
 * {@code byd/_dudu_extract/dex/smali_dudu/c1/com/dudu/autoui/manage/shellManage/bydSdk/DDBYDAutoDevice.smali}.
 *
 * <p>Subclassing pattern (per Dudu's 23 {@code DDBYDAuto<X>Device}
 * concrete subclasses + our {@code BydPushDevice}):
 *
 * <ol>
 *   <li>Override {@link #getDevicetype()} to return a fixed BYD
 *       device-type integer (1000 = AC, 1001 = BODY, 1004 = LIGHT,
 *       …; full table in
 *       {@code byd/BYD_FEATURE_IDS_FROM_DUDE.md}).
 *   <li>Construct via {@link #AbsBYDAutoDevice(Context)}; the
 *       framework auto-registers the instance for events on its
 *       device-type via the constructor side-effect (the
 *       framework-side "Service" walks every constructed
 *       {@code AbsBYDAutoDevice} on the system context and calls
 *       {@link #onPostEvent(IBYDAutoEvent)} for value-change events
 *       on its device-type).
 *   <li>Override {@link #onPostEvent(IBYDAutoEvent)} to receive
 *       push frames. Return {@code false} from your override (per
 *       Dudu's pattern in {@code AbsBYDAutoDeviceEx}) when you've
 *       handled the event and want to short-circuit further
 *       framework dispatch.
 * </ol>
 *
 * <p>compileOnly stub — see {@code byd-stub/build.gradle.kts}.
 * At runtime, the BYD-shipped framework provides the real
 * implementation; this stub is NOT in the APK classpath.
 *
 * <p>Method signatures here are EXACTLY what the Dudu smali calls
 * — adding a method requires confirming its signature in the smali
 * before stubbing it (anything else risks a runtime
 * {@code NoSuchMethodError} on a real BYD device).
 */
public abstract class AbsBYDAutoDevice {

    /**
     * Construct a device for the given Android context. The
     * framework auto-registers the instance for value-change events
     * on the integer returned by {@link #getDevicetype()} via this
     * constructor's side-effect.
     */
    public AbsBYDAutoDevice(Context context) {
        // Stub — real framework binds to the auto service here.
    }

    /**
     * BYD device-type integer this device handles
     * (1000 = AC, 1001 = BODY, 1041 = DOORLOCK, …). Subclasses
     * MUST override and return a constant.
     */
    public abstract int getDevicetype();

    // ── Synchronous get/set surface (we route through these via
    //    reflection on `autoMgr` in DashDaemon; the stubs are here
    //    so subclasses that want typed access compile, but the daemon
    //    doesn't actually call them via this base class.) ───────────

    public int get(int dt, int key) {
        throw new UnsupportedOperationException("stub");
    }

    public int set(int dt, int key, int value) {
        throw new UnsupportedOperationException("stub");
    }

    public int set(int dt, int key, byte[] value) {
        throw new UnsupportedOperationException("stub");
    }

    public int set(int dt, int[] keys, int[] values) {
        throw new UnsupportedOperationException("stub");
    }

    public double getDouble(int dt, int key) {
        throw new UnsupportedOperationException("stub");
    }

    public byte[] getBuffer(int dt, int key) {
        throw new UnsupportedOperationException("stub");
    }

    public int[] getIntArray(int dt, int[] keys) {
        throw new UnsupportedOperationException("stub");
    }

    public float[] getDoubleArray(int dt, int[] keys) {
        throw new UnsupportedOperationException("stub");
    }

    // ── Push entry-point ─────────────────────────────────────────

    /**
     * Framework calls this when ANY value change happens for this
     * device's {@link #getDevicetype()}. Override to catch push
     * frames; the (dt) is implied by {@code this.getDevicetype()},
     * the (key) comes from {@code event.getEventType()}, the value
     * comes from {@code event.getValue()} or
     * {@code event.getDoubleValue()} per signal type.
     *
     * Return {@code true} to let the framework continue its default
     * dispatch, {@code false} to short-circuit (per Dudu pattern).
     */
    public boolean onPostEvent(IBYDAutoEvent event) {
        // Stub — real framework default dispatch lives here.
        return true;
    }

    // ── Permission / metadata hooks (overridable, defaults are empty
    //    per Dudu; included so subclasses match the framework
    //    surface for callers that look them up reflectively) ─────

    public String getGetPermission() {
        return "";
    }

    public String getSetPermission() {
        return "";
    }

    public int[] getFeatureList() {
        return null;
    }

    // ── Push listener registration ───────────────────────────────────
    //
    // Verified from Dudu's smali (e.g.
    // c1/com/dudu/autoui/manage/console/impl/byd/api/a.smali):
    //
    //   invoke-super {p0, p1},
    //     Landroid/hardware/bydauto/AbsBYDAutoDevice;->registerListener(
    //       Landroid/hardware/IBYDAutoListener;)V
    //
    // The constructor alone does NOT begin push dispatch — the
    // framework only delivers value-change events to listeners that
    // have been explicitly registered via this method. Pair every
    // BydPushDevice construction with a registerListener call.

    public void registerListener(IBYDAutoListener listener) {
        // Stub — real framework wires the listener into its dispatch
        // table for this device's getDevicetype().
    }

    public void unregisterListener(IBYDAutoListener listener) {
        // Stub — real framework removes the listener from dispatch.
    }
}

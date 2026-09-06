package android.hardware;

/**
 * BYD framework push-event interface.
 *
 * ABI verified against a reference launcher built for the same
 * framework: the interface exposes {@code getEventType()},
 * {@code getValue()} and {@code getDoubleValue()}, as declared below.
 *
 * The framework dispatches events to whichever
 * {@link android.hardware.bydauto.AbsBYDAutoDevice} subclass has the
 * matching {@code getDevicetype()} value, so the (dt) tuple is
 * implied by {@code this.getDevicetype()} on the receiving device.
 * {@link #getEventType()} carries the BYD feature ID; {@link #getValue()}
 * carries the int value (or {@link #getDoubleValue()} when the signal
 * is a double-typed feature).
 *
 * compileOnly stub — see {@code byd-stub/build.gradle.kts}.
 */
public interface IBYDAutoEvent {
    /**
     * BYD feature ID that just changed. Same integer as the
     * {@code key} argument in {@code AbsBYDAutoDevice.get(dt, key)}.
     */
    int getEventType();

    /**
     * Integer value of the changed signal. Defined when the underlying
     * feature is int-typed (most of them). For double / byte buffer
     * signals, see {@link #getDoubleValue()} or framework-specific
     * methods we haven't reverse-engineered yet.
     */
    int getValue();

    /**
     * Double-precision value of the changed signal. Defined when the
     * underlying feature is declared as DOUBLE in the framework
     * (temperatures, pressures, humidity).
     */
    double getDoubleValue();
}

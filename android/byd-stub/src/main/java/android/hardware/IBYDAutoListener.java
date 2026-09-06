package android.hardware;

/**
 * BYD framework push-listener interface.
 *
 * ABI verified against a reference launcher built for the same
 * framework: implementors receive
 * {@code onDataChanged(IBYDAutoEvent)}, as declared below.
 *
 * <p>The framework dispatches value-change events through
 * {@link #onDataChanged(IBYDAutoEvent)} after a listener is
 * registered via {@code AbsBYDAutoDevice.registerListener(this)}.
 *
 * <p>Constructor-side registration of an
 * {@link android.hardware.bydauto.AbsBYDAutoDevice} alone is NOT
 * enough — verified empirically 12 May 2026: BydPushDevice
 * instances constructed without a follow-up registerListener call
 * receive ZERO push frames from the framework. Reference launchers
 * pair every device with a listener and call registerListener after
 * construction; we missed this step.
 *
 * <p>compileOnly stub — see {@code byd-stub/build.gradle.kts}.
 */
public interface IBYDAutoListener {
    /** Per-event push callback — fires for every value change on the
     *  registered device's dt. */
    void onDataChanged(IBYDAutoEvent event);
}

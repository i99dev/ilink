package android.hardware;

/**
 * BYD framework push-listener interface.
 *
 * Verified ABI from Dudu Launcher smali under
 * {@code byd/_dudu_extract/dex/smali_dudu/c1/com/dudu/autoui/manage/console/impl/byd/api/d.smali}:
 *
 * <pre>
 *   .implements Landroid/hardware/IBYDAutoListener;
 *
 *   .method public final onDataChanged(Landroid/hardware/IBYDAutoEvent;)V
 * </pre>
 *
 * <p>The framework dispatches value-change events through
 * {@link #onDataChanged(IBYDAutoEvent)} after a listener is
 * registered via {@code AbsBYDAutoDevice.registerListener(this)}.
 *
 * <p>Constructor-side registration of an
 * {@link android.hardware.bydauto.AbsBYDAutoDevice} alone is NOT
 * enough — verified empirically 12 May 2026: BydPushDevice
 * instances constructed without a follow-up registerListener call
 * receive ZERO push frames from the framework. Dudu wires every
 * device with a paired listener (`b.smali`, `b0.smali`, etc.) and
 * calls registerListener after construction; we missed this step.
 *
 * <p>compileOnly stub — see {@code byd-stub/build.gradle.kts}.
 */
public interface IBYDAutoListener {
    /** Per-event push callback — fires for every value change on the
     *  registered device's dt. */
    void onDataChanged(IBYDAutoEvent event);
}

package android.content;

/**
 * Stub for {@code android.content.Context}.
 *
 * The real class lives in the Android SDK. We stub it here only to
 * unblock the byd-stub module's compile (so it has zero external
 * dependencies on the SDK while still satisfying the {@code
 * AbsBYDAutoDevice(Context)} constructor signature).
 *
 * At runtime in the {@code :app} module, the real
 * {@code android.content.Context} from the Android SDK wins via
 * classpath ordering — this stub is {@code compileOnly} and never
 * ships in the APK.
 */
public class Context {
    // Intentionally empty. We don't call any methods on Context
    // from inside byd-stub; we only need the type to exist so
    // AbsBYDAutoDevice(Context) compiles.
}

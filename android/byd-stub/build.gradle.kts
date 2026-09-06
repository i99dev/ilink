/*
 * `byd-stub` — compileOnly framework SDK stubs.
 *
 * Lets DashDaemon extend `android.hardware.bydauto.AbsBYDAutoDevice`
 * at build time without bundling the full BYD framework jar.
 *
 * The classes here are zero-implementation placeholders that match
 * the framework ABI byte-for-byte (signatures verified against a
 * reference launcher that targets the same framework).
 * At RUNTIME they are NOT present in the APK — `compileOnly` keeps
 * the jar off the runtime classpath. The daemon runs via
 * `app_process64` against the BYD-shipped framework, so calls into
 * AbsBYDAutoDevice / IBYDAutoEvent dispatch to the real
 * BYD-shipped implementations.
 *
 * Why this exists: BYD does not publish their framework SDK as a
 * stub jar (the way Samsung / Xiaomi do). A reference launcher built
 * against that framework is the only source of truth we have for the
 * ABI; these stubs encode it as Java so the Java compiler can type-check
 * `BydPushDevice extends AbsBYDAutoDevice`.
 *
 * Adding a new method: only stub what `BydPushDevice` actually
 * overrides — the rest of the framework surface goes through
 * reflection on `autoMgr` (see `DashDaemon.initAutoService`).
 * Stubs are NOT a comprehensive SDK; they're the minimum needed
 * for compileOnly to succeed.
 */
plugins {
    id("java-library")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

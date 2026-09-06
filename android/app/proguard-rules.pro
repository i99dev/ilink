# dash R8 / ProGuard rules
#
# Philosophy: classes that are NOT referenced by name from outside Kotlin's
# view (Android manifest, JNI lookup table, app_process64 invocation,
# Dart MethodChannel string lookup) MUST be allowed to rename. R8 rewrites
# all internal Kotlin call-sites when it renames the class.
#
# Use:
#   -keep class X { ... }            → keep class NAME + members
#   -keepclassmembers class X { ... } → keep MEMBERS, class can rename
#   -keepclasseswithmembers ...       → drop class entirely if members vanish
#   -keepnames                        → keep name but allow shrink
#
# Only the FOUR classes below need their FQCN preserved:
#   1. MainActivity        — Android manifest <activity android:name=...>
#   2. DashDaemon          — `app_process64 / com.i99dev.ilink.helper.DashDaemon`
#   3. NativeSecrets       — JNI RegisterNatives lookup string in C++
#   4. VoiceSessionService — Android manifest <service android:name=...>
# Everything else gets renamed.

# ── Flutter framework — required for embedding to wire up plugins ──────
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.**

# ── Manifest-named entry points — Android instantiates these by FQCN ───
-keep class com.i99dev.ilink.MainActivity {
    public <init>(...);
    public void onCreate(android.os.Bundle);
    public void onDestroy();
    public void onNewIntent(android.content.Intent);
    public boolean dispatchKeyEvent(android.view.KeyEvent);
    public void configureFlutterEngine(io.flutter.embedding.engine.FlutterEngine);
}
-keep class com.i99dev.ilink.voice.VoiceSessionService { *; }

# Third-party services declared in manifest — leave names intact.
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.pichillilorenzo.flutter_inappwebview_android.** { *; }
-keep class com.baseflow.geolocator.** { *; }

# ── DashDaemon — out-of-process entry point launched via:
#     CLASSPATH=<apk> app_process64 / com.i99dev.ilink.helper.DashDaemon
# The CLASS NAME and `main` signature are looked up by string, so both
# must stay. Internal members of the class can rename freely.
-keep class com.i99dev.ilink.helper.DashDaemon {
    public static void main(java.lang.String[]);
    public <init>();
}

# ── NativeSecrets — JNI bridge bound via RegisterNatives in JNI_OnLoad
# (cpp/secrets.cpp). The FQCN string `com/i99dev/ilink/security/
# NativeSecrets` and the native method names (nativePing, nativeAbi,
# nativeTracerPid, nativeHasFridaInMaps, nativeTracedAtLoad) must match
# the C side byte-for-byte.
-keep class com.i99dev.ilink.security.NativeSecrets {
    private static native java.lang.String nativePing();
    private static native int nativeTracerPid();
    private static native boolean nativeHasFridaInMaps();
    private static native boolean nativeTracedAtLoad();
    private static native java.lang.String nativeAbi();
}
# Public Kotlin API (isAvailable, tracerPid(), tracedAtLoad(), abi()) is
# called from TamperProbes — which itself can be renamed, so this only
# needs its members preserved, not the class name.
-keepclassmembers class com.i99dev.ilink.security.NativeSecrets {
    public *;
}

# ── Dart MethodChannel handlers — channel name strings ARE preserved
# automatically (they're string literals in Kotlin). The handler classes
# themselves can be renamed because the call wires up via:
#   channel.setMethodCallHandler { ... }
# which R8 rewrites along with all other refs.
-keepclassmembers class com.i99dev.ilink.car.CarChannel {
    public <init>(...);
    public void register();
}
-keepclassmembers class com.i99dev.ilink.security.SecurityChannel {
    public <init>(...);
    public void register();
}

# ── Singletons accessed via Kotlin `INSTANCE` field — R8 understands
# Kotlin metadata and rewrites `Foo.INSTANCE` calls when Foo is renamed,
# but only if we keep the Kotlin metadata attribute (below). Members
# only — class names can change.
-keepclassmembers class com.i99dev.ilink.car.AutoFeatureService {
    public *;
}
-keepclassmembers class com.i99dev.ilink.car.AcFeatureService {
    public *;
}
-keepclassmembers class com.i99dev.ilink.car.UnitDispatcher {
    public *;
}
-keepclassmembers class com.i99dev.ilink.car.UnitDispatcher$Companion {
    public *;
}

# ── ActionIds: 50+ public static final String constants. R8 inlines
# constant-pool strings at every use-site, so the ActionIds class can
# disappear entirely. The action-id strings ("door.lock") still appear
# at the call sites — that's a Dart-side leak, not a Kotlin one.
# DON'T add a keep rule here — let R8 strip ActionIds completely.

# ── CarTable schema — Dart MethodChannel passes args that Kotlin
# constructs into FastAction/UnitAction/UnitSpec. These are pure data
# classes; their names can rename, but their constructors + getters
# must survive.
-keepclassmembers class com.i99dev.ilink.car.FastAction {
    public <init>(...);
    public *** getDt();
    public *** getKey();
    public *** getValueFn();
}
-keepclassmembers class com.i99dev.ilink.car.UnitAction {
    public <init>(...);
    public *** getUnit();
    public *** getArgs();
}
-keepclassmembers class com.i99dev.ilink.car.UnitSpec {
    public <init>(...);
    public *** getDex();
    public *** getClassName();
}

# CarTableSource implementation — internal only, no string lookup. Keep
# members so reflective getters work, allow class renames. EmptySource lives
# inside UnitDispatcher (private object) and rides UnitDispatcher's keep
# rule below.
-keepclassmembers class com.i99dev.ilink.car.EncryptedCarTableSource {
    public *;
}
-keepclassmembers class com.i99dev.ilink.car.EncryptedCarTableSource$Companion {
    public *;
}

# CarIdentity — accessed via Kotlin singleton. Members only.
-keepclassmembers class com.i99dev.ilink.car.CarIdentity {
    public *;
}

# DashDaemonClient — used internally by AdbShellBridge. Class can rename.
-keepclassmembers class com.i99dev.ilink.daemon.DashDaemonClient {
    public *;
}

# ADB embedded client — internal use only, class names CAN rename.
-keepclassmembers class com.i99dev.ilink.adb.AdbShellBridge {
    public *;
}

# Security helpers — internal callers only. Members preserved, class
# names can rename.
-keepclassmembers class com.i99dev.ilink.security.IntegrityMonitor {
    public *;
}
-keepclassmembers class com.i99dev.ilink.security.IntegrityMonitor$Companion {
    public *;
}
-keepclassmembers class com.i99dev.ilink.security.SecureLogger {
    public *;
}
-keepclassmembers class com.i99dev.ilink.security.SecureLogger$Companion {
    public *;
}
-keepclassmembers class com.i99dev.ilink.security.DeviceKeyMaterial {
    public *;
}
-keepclassmembers class com.i99dev.ilink.security.DeviceKeyMaterial$Companion {
    public *;
}
-keepclassmembers class com.i99dev.ilink.security.EncryptedAssetLoader {
    public *;
}
-keepclassmembers class com.i99dev.ilink.security.CryptoUtils {
    public *;
}
-keepclassmembers class com.i99dev.ilink.security.TamperProbes {
    public *;
}
-keepclassmembers class com.i99dev.ilink.security.SignaturePin {
    public *;
}
-keepclassmembers class com.i99dev.ilink.security.KeystoreWrap {
    public *;
}

# ── Reflection targets on the system side — names cannot be renamed.
-keepnames class android.hardware.bydauto.BYDAutoManager
-keepnames class com.byd.ac.**

# Methods called reflectively on system services.
-keepclassmembernames class * {
    public *** setInt(int, int, int);
    public *** getInt(int, int);
    public boolean transact(int, android.os.Parcel, android.os.Parcel, int);
}

# ── Kotlin metadata + coroutines + reflection ─────────────────────────
# Without RuntimeVisibleAnnotations Kotlin's INSTANCE/Companion lookup
# breaks. With it, R8 can still rename classes — annotations rewrite too.
-keepattributes RuntimeVisibleAnnotations,RuntimeVisibleParameterAnnotations
# Signature is needed by reflection on generic types; InnerClasses by
# Kotlin metadata for nested companion lookup. EnclosingMethod is needed
# for stack trace symbolication of inner anonymous classes.
-keepattributes Signature,InnerClasses,EnclosingMethod
# Rename source-file refs to a fictitious value so stack traces don't
# leak our package layout. Combined with -keepattributes SourceFile,LineNumberTable
# our own mapping.txt symbolicates correctly server-side; attackers see "SF".
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SF
-dontwarn kotlinx.coroutines.**

# ── Flutter deferred-components (unused) ──────────────────────────────
-dontwarn com.google.android.play.core.**

# ── Protobuf generated classes — reflection-heavy ──────────────────────
-keep class com.google.protobuf.** { *; }
-keep class com.i99dev.ilink.car.CarTableProto { *; }
-keep class com.i99dev.ilink.car.CarTableProto$** { *; }
-dontwarn com.google.protobuf.**

# ── Sentry — defensive keep ────────────────────────────────────────────
# The sentry-android AAR ships its own consumer-rules.pro that AGP
# auto-merges, and sentry_flutter v9 verified live on a v1.5.1-b
# release APK (SentryNdkPreloadProvider + SentryPerformanceProvider
# loaded; native crash hooks armed). This explicit keep is a defensive
# guardrail so a future R8 mode change or AAR-merge regression can't
# silently strip the SDK and disable crash capture mid-release.
-keep class io.sentry.** { *; }
-keep interface io.sentry.** { *; }
-dontwarn io.sentry.**

# ── Strip verbose Android logging from release ─────────────────────────
# Minify is on, but without this the ~190 Kotlin Log.v/d/i calls survive
# into release logcat — verbose info-disclosure on a fleet device (this
# OEM ROM happens to filter app logcat, but other ROMs may not, and it's
# noise regardless; the app's own diagnostics go to ota_diag.log, not
# logcat). `-assumenosideeffects` lets R8 drop calls whose return value is
# unused — which is every Log call. Keep w/e so warnings + errors still
# reach logcat for crash analysis. (None of these lines log raw secrets —
# verified in the audit — so this is hygiene, not a leak fix.)
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
    public static boolean isLoggable(java.lang.String, int);
}

# ── BydPushDevice — extends framework class AbsBYDAutoDevice. The framework
# invokes virtual methods on us (getDevicetype, getType, onPostEvent) by
# name, NOT by Java @Override resolution — our compileOnly stub doesn't
# even declare getType, so R8 sees the override as an unused public method
# and strips it. At runtime the framework throws AbstractMethodError.
# Keep the class name + every method that satisfies a runtime virtual
# dispatch from the framework or from in-app reflection.
-keep class com.i99dev.ilink.helper.BydPushDevice {
    public <init>(android.content.Context, int, com.i99dev.ilink.helper.BydPushDevice$PushSink);
    public int getDevicetype();
    public int getType();
    public boolean onPostEvent(android.hardware.IBYDAutoEvent);
    public int getInt(int);
    public double getDouble(int);
    public byte[] getBuffer(int);
    public int[] getIntArray(int[]);
    public int setInt(int, int);
    public int setBytes(int, byte[]);
    public int setMulti(int[], int[]);
}
-keep interface com.i99dev.ilink.helper.BydPushDevice$PushSink { *; }

# ── JNA + Vosk (on-device voice) ────────────────────────────────────────
# Vosk binds libvosk through JNA. JNA's native initIDs() resolves classes
# and fields by their EXACT names via JNI (e.g. the `peer` field on
# com.sun.jna.Pointer), so R8 must not rename, repackage, strip, or
# access-modify com.sun.jna.* / org.vosk.*. Without these keeps the release
# build crashes at org.vosk.LibVosk.<clinit> with "Can't obtain peer field
# ID for class com.sun.jna.Pointer" and on-device voice never starts —
# debug builds aren't minified, so this only bites release/prod.
-keep class com.sun.jna.** { *; }
-keepclassmembers class com.sun.jna.** { *; }
-keep class * extends com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class org.vosk.** { *; }
-keepclassmembers class org.vosk.** { *; }
-dontwarn java.awt.**
-dontwarn com.sun.jna.**

# apksig (cluster-app patcher, ClusterApkPatcher/PatchSigner). Its bundled
# V1 (JAR) signer references JDK-internal sun.security.* classes that don't
# exist on Android — but we sign V2-only (setV1SigningEnabled(false)), so that
# code path is never reached at runtime. Suppress R8's missing-class errors.
-dontwarn sun.security.**
-dontwarn com.android.apksig.internal.apk.v1.**
-dontwarn com.android.apksig.internal.jar.**

# On-device patcher entry point. Spawned by NAME via `app_process64 -cp <apk>
# com.i99dev.ilink.clusterpatch.OnDevicePatchKt …` (shell uid), so R8 must
# keep the class + main() unrenamed. Keeping the whole clusterpatch package
# also keeps its ARSCLib/apksig call graph reachable from this off-graph entry.
-keep class com.i99dev.ilink.clusterpatch.OnDevicePatchKt { public static void main(java.lang.String[]); }
-keep class com.i99dev.ilink.clusterpatch.** { *; }

# CAN-FID instrument-HAL writer + its M0 spike. The spike is an off-graph
# `app_process` entry (shell uid) — keep main() unrenamed; the writer + the
# BydGuidance send-sequences it drives must survive too.
-keep class com.i99dev.ilink.nav.transport.canfid.InstrumentHalWriterKt { public static void main(java.lang.String[]); }
-keep class com.i99dev.ilink.nav.transport.canfid.InstrumentHalWriter { *; }
-keep class com.i99dev.ilink.nav.transport.canfid.BydGuidance { *; }
-keep class com.i99dev.ilink.nav.transport.canfid.BydFid { *; }

# ── Aggressive renaming for everything else (the parts NOT listed
# above). R8 full mode is enabled by default in AGP 7+ with
# -allowaccessmodification + class-merging.
-allowaccessmodification
-repackageclasses 'a'

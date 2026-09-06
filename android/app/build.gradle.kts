import com.google.protobuf.gradle.proto
import java.io.File
import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Protobuf codegen for the CarTable schema at proto/car_table.proto.
    // Produces Java classes used by EncryptedCarTableSource at runtime.
    // protoc itself is pulled as a managed Maven artifact — no system install.
    id("com.google.protobuf")
}

// Parse --dart-define values that the Flutter Gradle plugin forwards as the
// `dart-defines` project property — comma-separated, base64-encoded KEY=VALUE
// pairs. Missing property -> empty map, so plain `./gradlew` builds still
// work (they fall back to the defaults set in buildConfigField below).
val dartDefines: Map<String, String> = run {
    val raw = (project.findProperty("dart-defines") as? String).orEmpty()
    if (raw.isEmpty()) return@run emptyMap()
    raw.split(",").mapNotNull { token ->
        val decoded: String = runCatching { String(Base64.getDecoder().decode(token)) }
            .getOrNull() ?: return@mapNotNull null
        val eq = decoded.indexOf('=')
        if (eq < 0) null else decoded.substring(0, eq) to decoded.substring(eq + 1)
    }.toMap()
}

fun dartDefine(key: String, fallback: String): String = dartDefines[key] ?: fallback

// Parse dash/.env once at top level so both `defaultConfig.buildConfigField`
// (which reads DASH_EXPECTED_SIGNER_SHA) AND `signingConfigs` (which reads
// DASH_KEYSTORE_*) can pull from the same source. Real shell env vars still
// take precedence — CI can inject without touching .env.
val dotenvMap: Map<String, String> = run {
    val envFile = rootProject.projectDir.parentFile.resolve(".env")
    if (!envFile.exists()) return@run emptyMap()
    envFile.readLines()
        .asSequence()
        .map { it.trim() }
        .filter { it.isNotEmpty() && !it.startsWith("#") }
        .mapNotNull { line ->
            val eq = line.indexOf('=')
            if (eq < 0) return@mapNotNull null
            val key = line.substring(0, eq).trim()
            val value = line.substring(eq + 1).trim()
                .removeSurrounding("\"")
                .removeSurrounding("'")
            key to value
        }
        .toMap()
}

fun envOrDotenv(key: String): String? =
    System.getenv(key)?.takeIf { it.isNotBlank() }
        ?: dotenvMap[key]?.takeIf { it.isNotBlank() }

android {
    namespace = "com.i99dev.ilink"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    buildFeatures {
        buildConfig = true
    }

    // Local unit tests run on a host JVM without the Android framework
    // jar; references to `android.util.Log` etc. throw `RuntimeException:
    // "Method i in android.util.Log not mocked"` by default. Setting
    // returnDefaultValues makes those calls no-op (return 0/null/false)
    // so pure-logic tests (e.g. AmShellRunnerTest) can exercise code
    // that incidentally logs. Instrumented tests would still run on a
    // device and see real Android — but we don't ship those yet.
    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    // NDK secrets module. libdash_secrets.so gets built for each ABI
    // listed in defaultConfig.ndk.abiFilters below and shipped under
    // lib/<abi>/ inside the APK. CMakeLists.txt + secrets.cpp live at
    // src/main/cpp; the Kotlin bridge is com.i99dev.ilink.security.NativeSecrets.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.i99dev.ilink"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ABI filters are set per-build-type below. defaultConfig used to
        // pin to "arm64-v8a" globally, which clobbered Flutter's x86_64
        // target for the emulator (Flutter compiles libflutter.so for the
        // target ABI; the global whitelist then stripped it, leaving the
        // APK with NO libflutter.so for either arch). Release builds still
        // lock down to arm64 in their own block.

        // Mirror of the compile-time AppConfig fields the Kotlin side needs.
        // Values flow from `--dart-define-from-file=config/*.json` → Flutter
        // Gradle plugin → `dart-defines` property → here. Defaults below must
        // match `lib/core/config/app_config.dart::fromEnvironment`.
        buildConfigField(
            "String", "DAEMON_HOST",
            "\"${dartDefine("DAEMON_HOST", "127.0.0.1")}\""
        )
        buildConfigField(
            "int", "DAEMON_PORT",
            dartDefine("DAEMON_PORT", "58733")
        )
        buildConfigField(
            "int", "ADBD_PORT",
            dartDefine("ADBD_PORT", "5555")
        )
        buildConfigField(
            "boolean", "MOCK_MODE",
            dartDefine("MOCK_MODE", "false")
        )
        // Expected SHA-256 of the release signing cert — consumed by
        // SignaturePin at runtime to detect repackaged APKs. Sourced from
        // shell env or dash/.env (`DASH_EXPECTED_SIGNER_SHA`). Empty
        // string in dev builds → SignaturePin treats as NoBaseline and
        // skips the check (so local builds don't false-positive).
        buildConfigField(
            "String", "EXPECTED_SIGNER_SHA",
            "\"${envOrDotenv("DASH_EXPECTED_SIGNER_SHA") ?: ""}\""
        )
    }

    // Release signing config — keys read from either a gitignored
    // `dash/.env` file OR real shell environment variables, via the
    // top-level `envOrDotenv()` helper. Real env vars take precedence so
    // CI can inject values without touching .env. Required for a real
    // signed build (all three):
    //   DASH_KEYSTORE_PATH      — absolute path to dash-release.jks
    //   DASH_KEYSTORE_PASSWORD  — keystore password
    //   DASH_KEY_PASSWORD       — key password (often same as keystore)
    //   DASH_KEY_ALIAS          — optional, defaults to "dash"
    //
    // When any of the required three is missing, the release build falls
    // back to the debug keystore so `flutter run --release` still works
    // for developers without the release keystore — they just can't ship.
    fun secret(key: String): String? = envOrDotenv(key)

    // Resolve DASH_KEYSTORE_PATH into an absolute java.io.File. Accepts:
    //   - Windows absolute:  C:/Users/...  or  C:\Users\...
    //   - Git Bash absolute: /c/Users/...  (rewritten to C:/Users/...)
    //   - POSIX absolute:    /Users/...    or  /home/...
    //   - Project-relative:  ../byd-dash-secrets/keystore/dash-release.jks
    // so the same .env works on Windows, macOS, and Linux without edits.
    fun resolveKeystore(raw: String): File {
        // Git Bash / MSYS2 writes /c/Users/... for C:\Users\... — Gradle on
        // Windows would otherwise parse that as a path relative to
        // android/app/, producing nonsense like android/app/c/Users/...
        val normalized = Regex("^/([a-zA-Z])/").find(raw)?.let { m ->
            raw.replaceFirst(Regex("^/([a-zA-Z])/"), "${m.groupValues[1].uppercase()}:/")
        } ?: raw
        val candidate = File(normalized)
        // Absolute paths (incl. the rewritten Git-Bash ones) are used as-is.
        // Relative paths resolve against the Flutter project root (dash/),
        // so `../byd-dash-secrets/keystore/...` means "sibling of dash/".
        return if (candidate.isAbsolute) candidate
        else rootProject.projectDir.parentFile.resolve(normalized)
    }

    val hasReleaseKeystore = listOf(
        "DASH_KEYSTORE_PATH",
        "DASH_KEYSTORE_PASSWORD",
        "DASH_KEY_PASSWORD",
    ).all { secret(it) != null }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = resolveKeystore(secret("DASH_KEYSTORE_PATH")!!)
                storePassword = secret("DASH_KEYSTORE_PASSWORD")!!
                keyAlias = secret("DASH_KEY_ALIAS") ?: "dash"
                keyPassword = secret("DASH_KEY_PASSWORD")!!
                // Force v1 (JAR) signing alongside v2/v3. AGP auto-drops v1 for
                // minSdk>=24, producing v2-only APKs (verified: 3.14–3.17). That
                // breaks OTA self-install on these BYD cars two ways:
                //   1. OtaChannel.checkApkSigner uses getPackageArchiveInfo, which
                //      only reads the v1/JAR signature of an APK FILE — for a v2-only
                //      APK it returns no cert → ok=false → OtaSignerMismatchException
                //      → the update aborts before install.
                //   2. BYD's OEM PackageInstaller can reject v2-only APKs outright
                //      ("App not installed" / INSTALL_PARSE_FAILED_NO_CERTIFICATES).
                // Same 2a47 cert, so no compatibility break.
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // Dev fallback. Prints a warning so it's obvious this APK
                // won't decrypt the CarTable asset — the signer SHA will
                // differ from the one used to encrypt it, so the encrypted
                // path will fail closed and the dispatcher stays on its
                // empty default. Every car action will return "unknown
                // action" until a properly-signed APK is installed.
                logger.warn(
                    "dash: release-keystore creds not found (neither env " +
                    "vars nor dash/.env) — release build signed with debug " +
                    "keystore. Bundled offline command tables remain available. " +
                    "Use your release signing key for compatible updates. " +
                    "See docs/offline-first/local-command-tables.md."
                )
                signingConfigs.getByName("debug")
            }

            // R8 full-mode shrink + obfuscate for release. The keep rules in
            // proguard-rules.pro are the allowlist for reflection / JNI / Dart
            // MethodChannel surfaces — everything else gets renamed.
            // `proguard-android-optimize.txt` is the AGP-shipped optimisation
            // template (different from `proguard-android.txt` — the optimize
            // variant runs additional method inlining + dead-code passes).
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )

            // Leopard 8 is arm64 only. armeabi-v7a intentionally omitted — no
            // 32-bit BYD trim we target. Locked here in release-only so the
            // prod APK has zero non-target ABI surface for attackers to use,
            // while debug builds keep whatever ABI Flutter targets for the
            // connected device/emulator (typically x86_64).
            ndk {
                abiFilters += setOf("arm64-v8a")
            }

        }

        debug {
            // Don't pin abiFilters here — let Flutter's Gradle plugin pick
            // the ABI from `--target-platform` / connected device. Manual
            // pinning conflicts with the plugin's variant mutation and
            // ends up with no libflutter.so in the APK.
            isMinifyEnabled = false
        }
    }

    // The .proto file lives one level up in the Flutter project so it's
    // shared with the Dart-side tools (encrypter, dumper). Point both
    // main + any future flavour sourceSets at it explicitly rather than
    // letting Gradle guess.
    sourceSets {
        getByName("main") {
            proto {
                srcDir("../../proto")
            }
        }
    }
}

// Release-only ABI lockdown. Using `androidComponents.onVariants` because
// `BuildType.packaging.jniLibs.excludes` placed inside `release { }`
// leaks to debug (AGP quirk) — verified by inspecting the debug APK,
// which lost `lib/x86_64/libflutter.so` whenever the release block held
// the excludes. The variant-scoped API in androidComponents applies
// strictly to the matching variant.
//
// Goal: prod APK ships only `lib/arm64-v8a/**`. Flutter's Gradle plugin
// pre-populates buildType.ndk.abiFilters with [armeabi-v7a, arm64-v8a,
// x86_64] (DEFAULT_PLATFORMS) — packaging-time excludes drop everything
// non-arm64 regardless of where the .so came from (CMake, AAR jniLibs,
// the Flutter engine artifact, or a third-party plugin).
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.addAll(
            listOf(
                "lib/armeabi-v7a/**",
                "lib/x86/**",
                "lib/x86_64/**",
                "lib/mips/**",
                "lib/mips64/**",
                // Sherpa-onnx / ONNX Runtime native libs (~31 MB): the
                // Arabic Moonshine SECOND-tier STT engine. Vosk is the
                // primary engine and stays bundled (libvosk.so). These
                // three are excluded from the prod APK and instead ride
                // INSIDE the on-demand Arabic Moonshine bundle the native
                // provisioner already downloads + unpacks to
                // `filesDir/vosk-models/<version>/` (which also holds the
                // .ort model). MoonshineFallbackEngine loads them by
                // absolute path from that dir (DT_NEEDED order:
                // onnxruntime → cxx-api → c-api). Release-only: debug keeps
                // them in-APK so on-car debug needs no download.
                // arm64-v8a only — the sole release ABI (see ndk.abiFilters).
                "lib/arm64-v8a/libonnxruntime.so",
                "lib/arm64-v8a/libsherpa-onnx-c-api.so",
                "lib/arm64-v8a/libsherpa-onnx-cxx-api.so",
            )
        )
    }
}

// Codegen config: declare the `java` builtin explicitly. Using the full
// Java generator (not `lite`) because the lite runtime drops TextFormat,
// which EncryptedCarTableSource.kt uses to parse the textproto we ship.
// When the asset flips to binary wire format, we can revisit lite.
protobuf {
    protoc {
        artifact = "com.google.protobuf:protoc:4.36.1"
    }
    generateProtoTasks {
        all().forEach { task ->
            task.builtins {
                create("java")
            }
        }
    }
}

dependencies {
    // Full Java runtime — includes TextFormat.merge for parsing the
    // textproto asset. ~1.5 MB APK cost; acceptable for the first
    // release, revisit when we switch to binary wire format.
    implementation("com.google.protobuf:protobuf-java:4.36.1")
    // MediaSessionCompat — used by PttMediaSession to capture
    // steering-wheel media buttons (MEDIA_PREVIOUS/NEXT) system-wide,
    // so the voice toggle works even when the Activity is backgrounded
    // or has lost focus (common on BYD multi-user head units).
    implementation("androidx.media:media:1.7.1")
    // media3 ExoPlayer — powers PassengerPlayerActivity, the standalone
    // (:tvpassenger process) live-TV player on the passenger display.
    // video_player can't render to a secondary display, and a second
    // decoder in the IVI's own process wedges this BYD/MT6983 unit; a
    // separate-process ExoPlayer is the proven path. -hls adds the HLS
    // source DefaultMediaSourceFactory auto-detects; -ui gives PlayerView.
    implementation("androidx.media3:media3-exoplayer:1.4.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.4.1")
    implementation("androidx.media3:media3-ui:1.4.1")
    // Vosk (Kaldi) — on-device, offline speech recognition for the
    // "Hey BYD" wake word + the command grammar fast-path (Phase 1b).
    // Bundles libvosk.so + the JNA bridge (same engine the in-market
    // leopard-assistant uses). The acoustic model is NOT bundled (~40 MB)
    // — it's provisioned out-of-band into filesDir (adb-push for dev, the
    // app_release CDN for the fleet), so the APK stays lean and the model
    // is retrainable without an app rebuild. See VoskModelStore.kt.
    implementation("com.alphacephei:vosk-android:0.3.47")
    // BYD framework SDK stubs — compileOnly so the jar never reaches
    // the runtime APK. At runtime the BYD-shipped framework provides
    // the real `android.hardware.bydauto.AbsBYDAutoDevice` /
    // `IBYDAutoEvent` classes via the system classpath; the stubs
    // exist purely so the daemon's `BydPushDevice` extends-clause
    // type-checks at build time. See
    // android/byd-stub/build.gradle.kts for the full rationale.
    compileOnly(project(":byd-stub"))

    // Cluster App Patcher (feat/cluster-app-patcher). Re-signs a target
    // app with a BYD-cluster-enabling manifest delta so it can be cast
    // to the instrument cluster when the native path is refused. Both
    // pure-JVM libs (no Android framework) so the patch logic is
    // host-unit-testable. See docs/plans/CLUSTER_APP_PATCHER_PLAN.md.
    //   ARSCLib  — robust binary AndroidManifest (AXML) editing, no aapt.
    //   apksig   — Google's APK v2/v3 signer (own versioning; 2.3.0 is
    //              the current Maven Central release, NOT an AGP version).
    implementation("io.github.reandroid:ARSCLib:1.3.5")
    implementation("com.android.tools.build:apksig:2.3.0")

    // Unit-test scaffolding. Runs on local JVM (not instrumented) —
    // `./gradlew :app:testDebugUnitTest`. Limited to pure-Kotlin
    // classes that don't touch the Android framework (e.g. AmShellRunner,
    // AmStackParser). Instrumented tests would need Robolectric or
    // a device; out of scope for the first scaffold.
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlin:kotlin-test-junit:2.3.21")
    // Real org.json on the unit-test classpath. android.jar ships only a
    // STUB org.json; with testOptions.returnDefaultValues=true its methods
    // return null/0, so any code that parses/builds JSON (PatchRegistry)
    // can't be host-tested against the stub. This shadows the stub at test
    // runtime with a working implementation.
    testImplementation("org.json:json:20250517")
}

flutter {
    source = "../.."
}

// Catch stale incremental assets from older private release pipelines before
// packaging. A signer-derived encrypted fleet key is still a shared credential.
val verifyNoFleetAdbCredential by tasks.registering {
    doLast {
        check(!file("src/main/assets/adb_key.enc").exists()) {
            "Remove stale assets/adb_key.enc: shared ADB private keys must not be bundled."
        }
        val privateSigningResources = fileTree("src/main/resources") {
            include("**/*.pk8", "**/*.p12", "**/*.jks", "**/*.keystore")
        }
        check(privateSigningResources.isEmpty) {
            "Private signing keys must not be packaged as application resources."
        }
        listOf(
            "src/main/assets/offline/car_table.textproto",
            "src/main/assets/offline/mini_app_table.textproto",
            "src/main/assets/offline/units/manifest.json",
            "src/main/assets/offline/voice/en-0.15.zip",
            "../../assets/byd/catalog.tsv",
            "../../assets/byd/catalog_meta.yaml",
        ).forEach { path ->
            check(file(path).isFile && file(path).length() > 0) {
                "Required public offline asset missing: $path. Restore it from the repository."
            }
        }
    }
}
tasks.matching { it.name == "preBuild" }.configureEach {
    dependsOn(verifyNoFleetAdbCredential)
}

// Host unit tests that drive apksig (ClusterApkPatcherTest) need access to
// JDK-internal `sun.security.*` packages. apksig's DefaultApkSignerEngine
// initialises V1SchemeSigner in its <clinit>, which references
// sun.security.x509 even when V1 signing is disabled — and JDK 17+ closes
// that package via JPMS, throwing IllegalAccessError. This is a HOST-ONLY
// concern: on Android/ART there are no modules and these classes are part
// of libcore, so the on-device patch path is unaffected. Open them only
// for the test JVM.
tasks.withType<org.gradle.api.tasks.testing.Test>().configureEach {
    jvmArgs(
        "--add-exports=java.base/sun.security.x509=ALL-UNNAMED",
        "--add-opens=java.base/sun.security.x509=ALL-UNNAMED",
        "--add-exports=java.base/sun.security.pkcs=ALL-UNNAMED",
        "--add-opens=java.base/sun.security.pkcs=ALL-UNNAMED",
    )
}

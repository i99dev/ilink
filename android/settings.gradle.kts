pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // Pinned to the pre-Dependabot baseline. The Flutter plugin
    // ecosystem (e.g. audio_session-0.2.3) still applies the legacy
    // `kotlin-android` plugin internally, which conflicts with AGP 9's
    // built-in Kotlin. Likewise Kotlin 2.3+ errors on the old
    // `kotlinOptions` DSL that Flutter plugins still emit. Holding
    // these at the last known-good combo until the ecosystem migrates.
    // Dependabot is configured to skip these bumps — see .github/dependabot.yml.
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.21" apply false
    // Protobuf codegen — pulls protoc as a managed artifact from Maven so
    // a system-wide protoc install isn't required.
    id("com.google.protobuf") version "0.10.0" apply false
}

include(":app")
// `byd-stub` — compileOnly framework SDK stubs that let the daemon
// extend `android.hardware.bydauto.AbsBYDAutoDevice` at build time.
// See android/byd-stub/build.gradle.kts for rationale.
include(":byd-stub")

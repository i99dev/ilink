package com.i99dev.ilink

import android.content.Context
import com.i99dev.ilink.boot.BootPlatformPlugin
import com.i99dev.ilink.car.CarProfilePlatformPlugin
import com.i99dev.ilink.clusterpatch.ClusterPatchPlugin
import com.i99dev.ilink.cursor.CursorPlatformPlugin
import com.i99dev.ilink.device.ModelDetectorChannel
import com.i99dev.ilink.display.DisplayPlatformPlugin
import com.i99dev.ilink.display.SurfacePlatformPlugin
import com.i99dev.ilink.input.InputPlatformPlugin
import com.i99dev.ilink.launcher.LauncherBootstrapPlugin
import com.i99dev.ilink.launcher.LauncherPrivilegePlugin
import com.i99dev.ilink.nav.NavHudPlatformPlugin
import com.i99dev.ilink.pkg.PackagePlatformPlugin
import com.i99dev.ilink.tv.TvIviPlugin
import io.flutter.plugin.common.BinaryMessenger

/**
 * Native-capability plugin registry.
 *
 * Each plugin owns its own MethodChannel + (optionally) EventChannel
 * and has a [dispose] hook for tear-down. They share two constructor
 * arguments: applicationContext + messenger. This registry keeps the
 * argument plumbing in one place so MainActivity doesn't grow a
 * nullable field per plugin.
 *
 * Plugins that follow the older `Channel.register()` pattern (Car,
 * Security, NetworkInfo, Voice, OTA, HomeScreenShortcut) are NOT
 * tracked here — they're stateless or self-contained and don't
 * benefit from the lifecycle plumbing. MainActivity instantiates
 * those directly.
 *
 * Lifecycle:
 *   * [installAll] — instantiates every plugin and returns a handle.
 *     Idempotent in the sense that a fresh handle is returned each
 *     call (no global state).
 *   * [PlatformPluginsHandle.disposeAll] — calls every plugin's
 *     `dispose()` once. Safe to call multiple times; subsequent
 *     calls are no-ops.
 *
 * Adding a plugin: register it in [installAll] and add the
 * `dispose()` call to the handle's list. No edits elsewhere.
 */
object PlatformPlugins {
    fun installAll(
        applicationContext: Context,
        messenger: BinaryMessenger,
    ): PlatformPluginsHandle {
        val display = DisplayPlatformPlugin(applicationContext, messenger)
        val surface = SurfacePlatformPlugin(applicationContext, messenger)
        val input = InputPlatformPlugin(applicationContext, messenger)
        val cursor = CursorPlatformPlugin(applicationContext, messenger)
        val pkg = PackagePlatformPlugin(applicationContext, messenger)
        val boot = BootPlatformPlugin(applicationContext, messenger)
        val modelDetector = ModelDetectorChannel(applicationContext, messenger)
        // CarProfile — single source of truth for "what works on this
        // car right now". Both gates (CarCommandRouter + mini-app
        // catalog filter) consult this through the Dart-side
        // carProfileProvider.
        val carProfile = CarProfilePlatformPlugin(messenger)
        // Phase L1 — read-only probe of launcher-mode privileges
        // (WRITE_SECURE_SETTINGS, READ_LOGS, default-home, a11y-on,
        // etc.). Surfaces in Settings → Diagnostics so the user can
        // see what's missing before opting into launcher mode.
        val launcherPrivilege = LauncherPrivilegePlugin(applicationContext, messenger)
        // Phase L2 — bootstrap dispatcher. Issues `pm grant` /
        // `appops set` / `cmd package set-home-activity` over the
        // existing loopback-ADB shell to flip the launcher-tier
        // perms on, plus toggles the HomeActivityAlias enabled-state
        // directly via PackageManager. Idempotent — safe to re-run
        // as a recovery path after a partial failure.
        val launcherBootstrap = LauncherBootstrapPlugin(applicationContext, messenger)
        // Native full-screen IVI live-TV player launcher. The player
        // (TvIviPlayerActivity) and the passenger cast (PassengerLauncher /
        // PassengerPlayerActivity) are native — embedded Flutter video
        // can't render on this BYD ROM.
        val tvIvi = TvIviPlugin(applicationContext, messenger)
        // Cluster-app patcher (feat/cluster-app-patcher). Re-signs a foreign
        // app with the BYD split/cluster manifest delta when the native cast
        // is refused. The Dart side calls this only after a native cluster
        // cast fails + the user consents. See clusterpatch/.
        val clusterPatch = ClusterPatchPlugin(applicationContext, messenger)
        // Nav-HUD (feat/nav-hud). Pushes turn-by-turn guidance onto the BYD
        // factory instrument cluster via the preferred transport (ADB-free
        // SOME/IP → CAN-FID HAL fallback). Sourced from Maps/Waze/Yandex; armed
        // by the Dart side on the voice "navigate" hand-off. See nav/.
        val navHud = NavHudPlatformPlugin(applicationContext, messenger)
        return PlatformPluginsHandle(
            disposers = listOf(
                display::dispose,
                surface::dispose,
                input::dispose,
                cursor::dispose,
                pkg::dispose,
                boot::dispose,
                modelDetector::dispose,
                carProfile::dispose,
                launcherPrivilege::dispose,
                launcherBootstrap::dispose,
                tvIvi::dispose,
                clusterPatch::dispose,
                navHud::dispose,
            ),
        )
    }
}

/**
 * Opaque handle returned by [PlatformPlugins.installAll]. Holds the
 * dispose closures so MainActivity can tear plugins down without
 * tracking each instance.
 */
class PlatformPluginsHandle(private val disposers: List<() -> Unit>) {
    private var disposed = false

    fun disposeAll() {
        if (disposed) return
        disposed = true
        for (d in disposers) {
            runCatching { d() }
        }
    }
}

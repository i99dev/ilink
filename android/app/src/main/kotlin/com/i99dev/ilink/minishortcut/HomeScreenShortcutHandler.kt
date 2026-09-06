package com.i99dev.ilink.minishortcut

import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Log
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.i99dev.ilink.R
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Platform side of the mini-app "Add to Home Screen" feature.
 *
 * Contract — mirrored by [AndroidHomeScreenShortcutService] on the Dart side:
 *
 *   method  : "isPinSupported"  → returns Boolean (ShortcutManagerCompat.isRequestPinShortcutSupported)
 *   method  : "pinShortcut"     → arguments {
 *                                    id: String,
 *                                    label: String,
 *                                    deepLinkUrl: String,
 *                                    iconFilePath: String  (empty = use launcher icon)
 *                                  }
 *                                  returns Unit on success; throws one of:
 *                                    code "UNSUPPORTED_SDK"        — requestPinShortcut unavailable
 *                                    code "LAUNCHER_UNSUPPORTED"   — active launcher lacks pin
 *                                    code "LAUNCHER_REFUSED"       — pin request returned false
 *                                    code "INVALID_ARGS"           — malformed args from Dart
 *
 * The Dart side maps these onto typed [HomeScreenShortcutError] subtypes;
 * unmapped codes fall through to ChannelFailureError so a new failure
 * mode surfaces cleanly rather than being swallowed.
 *
 * Networking policy: this handler does not download icons. The caller
 * passes a local file path (from `flutter_cache_manager`'s DefaultCache).
 * An empty string is the sentinel for "use the bundled launcher icon" —
 * the Dart controller uses it after its own retry+fallback logic exhausts.
 */
class HomeScreenShortcutHandler(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        const val CHANNEL = "ilink/home_screen_shortcut"
        private const val TAG = "HomeScreenShortcutHandler"

        // ShortcutManagerCompat pin support landed on the compat layer
        // in library form before the platform API (API 26), but the
        // compat call is still a no-op below 26. Gate at the call site
        // so the Dart layer sees a consistent "UNSUPPORTED_SDK" rather
        // than a silent false return on some OEMs.
        private const val MIN_PIN_SDK = 26
    }

    private val channel = MethodChannel(messenger, CHANNEL)

    fun register() {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isPinSupported" -> handleIsPinSupported(result)
                "pinShortcut"    -> handlePinShortcut(call, result)
                else             -> result.notImplemented()
            }
        }
    }

    private fun handleIsPinSupported(result: MethodChannel.Result) {
        if (android.os.Build.VERSION.SDK_INT < MIN_PIN_SDK) {
            result.success(false); return
        }
        val ok = try {
            ShortcutManagerCompat.isRequestPinShortcutSupported(context)
        } catch (t: Throwable) {
            Log.w(TAG, "isRequestPinShortcutSupported threw", t)
            false
        }
        result.success(ok)
    }

    private fun handlePinShortcut(call: MethodCall, result: MethodChannel.Result) {
        if (android.os.Build.VERSION.SDK_INT < MIN_PIN_SDK) {
            result.error("UNSUPPORTED_SDK", "pin requires API 26+", null); return
        }

        val id = call.argument<String>("id")
        val label = call.argument<String>("label")
        val deepLinkUrl = call.argument<String>("deepLinkUrl")
        val iconFilePath = call.argument<String>("iconFilePath") ?: ""
        if (id.isNullOrBlank() || label.isNullOrBlank() || deepLinkUrl.isNullOrBlank()) {
            result.error("INVALID_ARGS", "id/label/deepLinkUrl are required", null); return
        }

        val supported = runCatching {
            ShortcutManagerCompat.isRequestPinShortcutSupported(context)
        }.getOrDefault(false)
        if (!supported) {
            result.error("LAUNCHER_UNSUPPORTED", "active launcher does not support pin shortcuts", null)
            return
        }

        val icon = loadIcon(iconFilePath)
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(deepLinkUrl)).apply {
            `package` = context.packageName
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val shortcut = ShortcutInfoCompat.Builder(context, "mini_app_$id")
            .setShortLabel(label)
            .setLongLabel(label)
            .setIcon(icon)
            .setIntent(intent)
            .build()

        val ok = try {
            ShortcutManagerCompat.requestPinShortcut(context, shortcut, null)
        } catch (t: Throwable) {
            Log.w(TAG, "requestPinShortcut threw for id=$id", t)
            false
        }
        if (ok) result.success(null)
        else result.error("LAUNCHER_REFUSED", "launcher refused pin request", null)
    }

    /**
     * Decode the caller-supplied icon into an [IconCompat]. Empty path
     * or any decode failure falls back to the bundled launcher icon so
     * the pin still succeeds — the Dart layer maps the empty-path case
     * to `PinPartial`; the decode-failure case logs here and also ends
     * up with the launcher icon (indistinguishable to the user).
     */
    private fun loadIcon(path: String): IconCompat {
        if (path.isBlank()) return launcherFallbackIcon()
        val file = File(path)
        if (!file.isFile) {
            Log.w(TAG, "icon path does not exist: $path")
            return launcherFallbackIcon()
        }
        val bitmap = try {
            BitmapFactory.decodeFile(file.absolutePath)
        } catch (t: Throwable) {
            Log.w(TAG, "BitmapFactory.decodeFile threw for $path", t)
            null
        }
        return if (bitmap != null) {
            // Adaptive bitmap gives the launcher room to mask corners /
            // apply its own shape. `createWithAdaptiveBitmap` expects the
            // full bitmap (the launcher crops to the safe zone itself),
            // which matches what cached_network_image cached at
            // presentation size.
            IconCompat.createWithAdaptiveBitmap(bitmap)
        } else {
            launcherFallbackIcon()
        }
    }

    private fun launcherFallbackIcon(): IconCompat =
        IconCompat.createWithResource(context, R.mipmap.ic_launcher)
}

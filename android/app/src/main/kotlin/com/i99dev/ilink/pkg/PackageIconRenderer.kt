package com.i99dev.ilink.pkg

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.os.Build
import android.util.Base64
import android.util.Log
import io.flutter.plugin.common.MethodCall
import java.io.ByteArrayOutputStream

/**
 * Renders + caches launcher icons for the `pkg.icon` channel op.
 *
 * Extracted from [PackagePlatformPlugin] (which kept growing past 2k
 * lines): this is the fully self-contained icon concern — it touches only
 * [Context] (for PackageManager), holds its own LRU, and shares no state
 * with the launch / move-stack / cluster machinery. The plugin delegates
 * `"icon"` straight to [icon].
 */
class PackageIconRenderer(private val context: Context) {
    private val iconCache = IconCache(ICON_CACHE_CAPACITY)

    /**
     * Resolve a versioned cache key for `packageName`, returning a
     * rendered PNG (base64) or a sticky negative result. Caching is keyed
     * on `package@versionCode` so an app update invalidates its icon but a
     * repeated poll for an unchanged package doesn't re-render.
     */
    fun icon(call: MethodCall): Map<String, Any?> {
        val packageName = call.argument<String>("packageName")
        if (packageName == null || !PACKAGE_NAME_REGEX.matches(packageName)) {
            return mapOf("ok" to false, "error" to "packageName invalid")
        }
        val pm = context.packageManager
        val versionCode = try {
            val pkgInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0L))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(packageName, 0)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pkgInfo.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                pkgInfo.versionCode.toLong()
            }
        } catch (e: PackageManager.NameNotFoundException) {
            return mapOf("ok" to false, "error" to "package not installed")
        }
        val key = "$packageName@$versionCode"
        val cached = iconCache.get(key)
        if (cached != null) {
            return if (cached.pngBase64 != null) {
                mapOf(
                    "ok" to true,
                    "pngBase64" to cached.pngBase64,
                    "iconHash" to key,
                )
            } else {
                // Negative cache hit — we tried before and the package
                // had no loadable icon. Return same shape mini-app sees
                // for "no icon"; it'll fall back to the first-letter
                // tile without re-asking.
                mapOf("ok" to false, "error" to (cached.error ?: "no icon"))
            }
        }
        // Render. The Drawable comes from PackageManager which crosses
        // a process boundary; do the bitmap work here on the
        // MethodChannel thread — a single render is ~5–15 ms on a
        // Leopard 8 head unit, comfortably under the 16 ms frame
        // budget. The full grid's first paint serialises calls anyway
        // (mini-app's IntersectionObserver + the JS bridge being
        // single-flighted), so a parallel thread pool buys nothing.
        val drawable: Drawable? = try {
            pm.getApplicationIcon(packageName)
        } catch (e: PackageManager.NameNotFoundException) {
            null
        }
        if (drawable == null) {
            iconCache.put(key, IconEntry(pngBase64 = null, error = "drawable null"))
            return mapOf("ok" to false, "error" to "no icon")
        }
        val pngBytes = renderDrawableToPng(drawable, ICON_RENDER_PX)
        if (pngBytes == null) {
            iconCache.put(key, IconEntry(pngBase64 = null, error = "render failed"))
            return mapOf("ok" to false, "error" to "render failed")
        }
        // NO_WRAP: line-wrapped base64 inflates the JSON we send back
        // through the bridge by ~1.4% and forces the SDK to strip
        // newlines before feeding to data URLs.
        val b64 = Base64.encodeToString(pngBytes, Base64.NO_WRAP)
        iconCache.put(key, IconEntry(pngBase64 = b64, error = null))
        return mapOf("ok" to true, "pngBase64" to b64, "iconHash" to key)
    }

    /**
     * Composite [drawable] onto a [size]×[size] ARGB bitmap and PNG-
     * encode it. Returns null on failure (zero-size drawable, OOM on
     * very large source bitmaps — neither expected for app icons).
     *
     * The intrinsic size of the source drawable is ignored; we always
     * draw at the target size so a tiny icon doesn't ship as a
     * 48×48 PNG and a giant adaptive icon doesn't waste bytes.
     */
    private fun renderDrawableToPng(drawable: Drawable, size: Int): ByteArray? {
        return try {
            val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)
            val baos = ByteArrayOutputStream(8 * 1024)
            val ok = bmp.compress(Bitmap.CompressFormat.PNG, 100, baos)
            bmp.recycle()
            if (!ok) null else baos.toByteArray()
        } catch (t: Throwable) {
            Log.w(TAG, "icon render failed: ${t.javaClass.simpleName}: ${t.message}")
            null
        }
    }

    companion object {
        private const val TAG = "PackageIconRenderer"

        /** Square render size for `pkg.icon`. 96 px is the smallest
         *  power-of-2-ish bucket that still upscales cleanly to a
         *  56 px grid tile on a 2× density head unit. */
        private const val ICON_RENDER_PX = 96

        /** Hard cap on the icon-cache LRU. 200 × ~8 KB ≈ 1.6 MB, far
         *  below the dashboard process's heap budget. A device with
         *  more launchable apps than this just rotates the cold ones. */
        private const val ICON_CACHE_CAPACITY = 200

        private val PACKAGE_NAME_REGEX = Regex("""^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$""")
    }
}

/**
 * Tiny LRU for rendered launcher icons. Synchronized because the
 * MethodChannel is normally serial but we don't want to bake that
 * assumption in — a future caller running `pkg.icon` from a
 * background queue should not corrupt the map.
 *
 * Stores either a successful render (pngBase64 != null) or a sticky
 * negative result (pngBase64 == null with an error reason). Negative
 * caching prevents a misbehaving package from re-rendering on every
 * grid scroll.
 */
private class IconCache(private val capacity: Int) {
    private val store: LinkedHashMap<String, IconEntry> =
        object : LinkedHashMap<String, IconEntry>(64, 0.75f, true) {
            override fun removeEldestEntry(
                eldest: MutableMap.MutableEntry<String, IconEntry>,
            ): Boolean = size > capacity
        }

    @Synchronized
    fun get(key: String): IconEntry? = store[key]

    @Synchronized
    fun put(key: String, entry: IconEntry) {
        store[key] = entry
    }
}

private data class IconEntry(val pngBase64: String?, val error: String?)

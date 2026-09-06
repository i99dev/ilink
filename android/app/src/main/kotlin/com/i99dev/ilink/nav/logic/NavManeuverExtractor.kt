package com.i99dev.ilink.nav.logic

import android.annotation.SuppressLint
import android.app.Notification
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Icon
import android.widget.RemoteViews

/**
 * The single place that derives a maneuver code (1..49) from an ongoing nav
 * notification, in priority order:
 *
 *   1. TITLE text — universal. Strip a leading distance ("In 500 m, …" /
 *      "500 m – …") then classify the remaining instruction with [ManeuverTextMap].
 *      This alone fixes most apps (the direction word is in the title).
 *   2. LARGE ICON — when the title is non-committal. First by the icon's
 *      RESOURCE NAME (apps name the arrow drawable, e.g. "…slight_left…"), which
 *      classifies as text; then, if the icon is a raster, by PERCEPTUAL HASH
 *      against the known arrow set ([WazeArrowRegistry]). This covers apps whose
 *      title has no direction (the arrow is the only signal).
 *
 *   3. CUSTOM LAYOUT — when neither the title nor the large icon decides, read the
 *      maneuver-arrow drawable NAME out of the notification's custom RemoteViews
 *      image actions (resolved against the POSTING app's resources) and classify it
 *      as text. Covers apps whose arrow lives only in a custom layout (e.g. a maneuver
 *      balloon). The reflection over the layout's action list is fully guarded and
 *      ROM-agnostic — it resolves every resource-id-shaped int and lets the classifier
 *      pick the arrow, so an unfamiliar layout degrades to null, never throws.
 *
 * Returns null when nothing decides → the caller keeps the prior maneuver (the
 * bus is not overwritten). Every non-text step is exception-guarded; a hostile
 * or unfamiliar notification degrades to the next step or null, never throws.
 *
 * Text helpers are host-testable ([extractFromTitle], [stripLeadingDistance]);
 * the icon steps need a device and are covered on-car.
 */
object NavManeuverExtractor {

    // Single-slot result cache. onNotificationPosted calls extract() serially on the
    // binder thread, often with IDENTICAL text on a burst (some apps post many
    // updates/sec). One @Volatile slot (lock-free, mirrors NavManeuverBus) lets a
    // duplicate post skip the expensive icon loadDrawable / RemoteViews reflection /
    // bitmap render. Keyed on package + the three text fields; a null result is cached
    // too. Only the Int? is held — never an Icon/Bitmap/Parcel (no IPC-handle leak).
    private data class Memo(
        val pkg: String, val title: String?, val text: String?, val subText: String?, val code: Int?,
    )

    @Volatile private var memo: Memo? = null

    /**
     * @param pkg          the posting package (selects per-app handling / cache key)
     * @param notification the ongoing notification
     * @param context      app context (to load the icon drawable / resolve names)
     * @return 1..49 maneuver code, or null if undecidable
     */
    fun extract(pkg: String, notification: Notification, context: Context): Int? {
        val e = notification.extras
        val title = e?.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val text = e?.getCharSequence(Notification.EXTRA_TEXT)?.toString()
        val subText = e?.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()

        memo?.let { m ->
            if (m.pkg == pkg && m.title == title && m.text == text && m.subText == subText) return m.code
        }
        val code = computeManeuver(pkg, title, notification, context)
        memo = Memo(pkg, title, text, subText, code)
        return code
    }

    /** The extraction ladder (title → large-icon → custom-layout). Only run on a cache
     *  miss — the expensive icon/RemoteViews work is skipped for duplicate posts. */
    private fun computeManeuver(pkg: String, title: String?, notification: Notification, context: Context): Int? {
        // 1) TITLE — universal, cheapest, most reliable.
        extractFromTitle(title)?.let { return it }

        // 1b) TEXT / BIG_TEXT — some apps (notably Google Maps) put only the distance
        //     in the title ("190 m") and the actual instruction in the text field
        //     ("Make a U-turn"). Run those through the SAME confident-only text ladder
        //     (extractFromTitle commits only on a real turn word; unknown/straight →
        //     null), so we get the maneuver from the words before falling back to the
        //     far less reliable large-icon perceptual hash.
        val e = notification.extras
        extractFromTitle(e?.getCharSequence(Notification.EXTRA_TEXT)?.toString())?.let { return it }
        extractFromTitle(e?.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString())?.let { return it }

        // 2) LARGE ICON — resource-name first (free), then raster perceptual hash.
        runCatching { notification.getLargeIcon() }.getOrNull()?.let { icon ->
            classifyIconByResName(icon, context)?.let { return it }
            classifyIconByBitmap(icon, context)?.let { return it }
        }

        // 3) CUSTOM-LAYOUT arrow — some apps put the maneuver ONLY in a custom
        //    RemoteViews image (no direction in the title, no usable large-icon).
        //    Resolve the layout's image resource NAMES against the posting app and
        //    classify. Fully guarded; degrades to null (status quo) on any ROM shape.
        classifyCustomLayoutArrow(pkg, notification, context)?.let { return it }

        return null
    }

    /**
     * Every drawable resource-entry-name (lowercased) referenced by the
     * notification's large icon + custom layouts, resolved in the posting app.
     * Shared with [NavAlertExtractor] (Yandex encodes camera/safety as icon names).
     * Fully guarded — an unfamiliar ROM shape yields an empty list, never throws.
     */
    fun resourceEntryNames(pkg: String, notification: Notification, context: Context): List<String> {
        val names = ArrayList<String>(8)
        runCatching { notification.getLargeIcon() }.getOrNull()?.let { icon ->
            iconResName(icon, context)?.let { names.add(it) }
        }
        runCatching {
            val res = context.packageManager.getResourcesForApplication(pkg)
            for (rv in listOfNotNull(notification.bigContentView, notification.contentView, notification.headsUpContentView)) {
                for (resId in resourceIdsFromRemoteViews(rv)) {
                    runCatching { res.getResourceEntryName(resId).lowercase() }.getOrNull()?.let { names.add(it) }
                }
            }
        }
        return names
    }

    // ---- (1) Title text ---------------------------------------------------

    /** Public for host tests: strip leading distance, classify; null if the text
     *  yields only STRAIGHT/blank (so the icon step gets a chance). */
    fun extractFromTitle(title: String?): Int? {
        if (title.isNullOrBlank()) return null
        val code = ManeuverTextMap.classify(stripLeadingDistance(title))
        // Only commit on a *confident* maneuver. STRAIGHT here means "title had no
        // turn word" → let the large-icon path try before we settle.
        return code.takeIf { it != ManeuverCatalog.STRAIGHT }
    }

    // "In 500 m, turn left" → "turn left"; "500 m – Turn right" → "Turn right";
    // "1,2 km · Keep left" → "Keep left". Leading distance + separator only.
    private val LEADING_DISTANCE = Regex(
        """^\s*(?:in|after|within|за|через)?\s*[\d.,]+\s*(?:m|km|mi|ft|yd|км|м|мили?|米)\b\s*[-–—:,·|]*\s*""",
        RegexOption.IGNORE_CASE,
    )

    /** Public for host tests. */
    fun stripLeadingDistance(title: String): String =
        LEADING_DISTANCE.replaceFirst(title, "").trim()

    // ---- (2) Large icon ---------------------------------------------------

    /** Apps name the arrow drawable (e.g. "ic_maneuver_slight_left"); the name
     *  classifies via the same text ladder. Only commit on a confident result. */
    private fun classifyIconByResName(icon: Icon, context: Context): Int? = runCatching {
        val name = iconResName(icon, context) ?: return null
        // Names use underscores ("slight_left"); the ladder already matches both
        // "slight_left" and "slight left", so pass the raw name.
        ManeuverTextMap.classify(name).takeIf { it != ManeuverCatalog.STRAIGHT }
    }.getOrNull()

    /** Resolve the icon's drawable resource name, when it is a RESOURCE icon in
     *  the posting app. Public APIs only; fully guarded (Icon.getResId is API 28 —
     *  runCatching covers the older-ROM NoSuchMethod path). */
    @SuppressLint("DiscouragedApi", "NewApi")
    private fun iconResName(icon: Icon, context: Context): String? = runCatching {
        // TYPE_RESOURCE == 2 (the only type with a resolvable name).
        if (icon.type != Icon.TYPE_RESOURCE) return null
        val resId = icon.resId
        if (resId == 0) return null
        val pkgName = icon.resPackage?.takeIf { it.isNotEmpty() } ?: return null
        val res = context.packageManager.getResourcesForApplication(pkgName)
        res.getResourceEntryName(resId).lowercase()
    }.getOrNull()

    /** Render the icon to a bitmap and match it against the known arrow set. This
     *  is the raster path: apps whose arrow is a drawn bitmap with no usable name
     *  and a non-committal title. */
    private fun classifyIconByBitmap(icon: Icon, context: Context): Int? = runCatching {
        val bmp = iconToBitmap(icon, context) ?: return null
        val w = bmp.width
        val h = bmp.height
        if (w <= 0 || h <= 0) return null
        val argb = IntArray(w * h)
        bmp.getPixels(argb, 0, w, 0, 0, w, h)
        WazeArrowRegistry.classify(argb, w, h)
    }.getOrNull()

    private fun iconToBitmap(icon: Icon, context: Context): Bitmap? = runCatching {
        val d = icon.loadDrawable(context) ?: return null
        if (d is BitmapDrawable) {
            d.bitmap
        } else {
            val w = d.intrinsicWidth.coerceAtLeast(1)
            val h = d.intrinsicHeight.coerceAtLeast(1)
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            d.setBounds(0, 0, w, h)
            d.draw(canvas)
            bmp
        }
    }.getOrNull()

    // ---- (3) Custom-layout (RemoteViews) arrow ----------------------------

    /** Walk the notification's custom layouts (big → content → heads-up); for each,
     *  resolve every image resource id to its NAME in the POSTING app's resources and
     *  classify via the same text ladder. First confident result wins. A maneuver
     *  balloon names its arrow drawable for the turn; a viewId / logo classifies to
     *  STRAIGHT and is skipped. Fully guarded → an unknown ROM shape returns null. */
    private fun classifyCustomLayoutArrow(pkg: String, n: Notification, context: Context): Int? = runCatching {
        val res = context.packageManager.getResourcesForApplication(pkg)
        val views = listOfNotNull(n.bigContentView, n.contentView, n.headsUpContentView)
        for (rv in views) {
            for (resId in resourceIdsFromRemoteViews(rv)) {
                val name = runCatching { res.getResourceEntryName(resId).lowercase() }.getOrNull() ?: continue
                val code = ManeuverTextMap.classify(name)
                if (code != ManeuverCatalog.STRAIGHT) return code
            }
        }
        null
    }.getOrNull()

    /** Reflect the RemoteViews action list and collect every resource-id-shaped int
     *  field value (package byte 0x7f app / 0x01 framework). ROM-agnostic: no
     *  dependence on a specific action class or field name — the caller resolves each
     *  to a name and lets the classifier pick the arrow. Fully guarded. */
    private fun resourceIdsFromRemoteViews(rv: RemoteViews): List<Int> = runCatching {
        val actions = remoteViewsActions(rv) ?: return emptyList()
        val out = ArrayList<Int>(8)
        for (action in actions) {
            if (action == null) continue
            var c: Class<*>? = action.javaClass
            while (c != null && c != Any::class.java) {
                for (f in c.declaredFields) {
                    if (f.type != Int::class.javaPrimitiveType) continue
                    runCatching {
                        f.isAccessible = true
                        val v = f.getInt(action)
                        val pkgByte = v ushr 24 // resource id = 0xPPTTNNNN
                        if (pkgByte == 0x7f || pkgByte == 0x01) out.add(v)
                    }
                }
                c = c.superclass
            }
        }
        out
    }.getOrElse { emptyList() }

    /** The private `mActions` list, found by walking the RemoteViews class hierarchy. */
    private fun remoteViewsActions(rv: RemoteViews): List<*>? {
        var c: Class<*>? = rv.javaClass
        while (c != null) {
            val f = runCatching { c!!.getDeclaredField("mActions") }.getOrNull()
            if (f != null) {
                f.isAccessible = true
                return runCatching { f.get(rv) as? List<*> }.getOrNull()
            }
            c = c.superclass
        }
        return null
    }
}

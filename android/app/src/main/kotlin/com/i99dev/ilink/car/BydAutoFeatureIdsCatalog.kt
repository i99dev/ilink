package com.i99dev.ilink.car

import android.util.Log

/**
 * Runtime-reflected dump of `android.hardware.bydauto.BYDAutoFeatureIds`.
 *
 * BYD's framework defines ~280+ `public static final int` constants on
 * the catalog class (and nested `$Safety` etc.); the integer values
 * live only in the framework jar, not in any APK we can read. This
 * object reflects on the class at first access and exposes the
 * `name → int` map so `[ExtraStatusKeys]` (and any future caller) can
 * reference fields by their stable BYD name without hard-coding an
 * integer that might drift across DiLink versions.
 *
 * Forward-compatible by design: a future ROM that adds new feature IDs
 * lights them up here automatically — `[ExtraStatusKeys]` just needs
 * the new name added to its list.
 *
 * Cached once. If the framework class isn't on the classloader (non-BYD
 * device, stripped framework), [byName] is empty and [resolve] returns
 * null for every call — the dispatcher drops those entries silently and
 * the diagnostics screen renders the matching gate rows grey.
 */
object BydAutoFeatureIdsCatalog {
    private const val TAG = "BydFidCatalog"
    private const val ROOT = "android.hardware.bydauto.BYDAutoFeatureIds"
    private const val INSTRUMENT_DEVICE =
        "android.hardware.bydauto.instrument.BYDAutoInstrumentDevice"

    /** Public static final int fields, keyed by the simple field name. */
    val byName: Map<String, Int> by lazy { loadByReflection() }

    /** Convenience: resolve one feature name. Returns null when the
     *  framework class is missing or the name isn't defined. */
    fun resolve(featureName: String): Int? = byName[featureName]

    /** Diagnostic — total count after reflection. Logged once at the
     *  daemon-init seam so a triager can confirm "we see N feature IDs"
     *  without touching this code. */
    fun size(): Int = byName.size

    /** Is the BYD instrument-cluster HAL on the (app) classpath? The Nav-HUD's
     *  CAN-FID path needs it; the M0 `diagnose` go/no-go reports it. Lives here
     *  so the `android.hardware.bydauto` package name stays in this one file. */
    fun isInstrumentDevicePresent(): Boolean =
        runCatching { Class.forName(INSTRUMENT_DEVICE); true }.getOrDefault(false)

    private fun loadByReflection(): Map<String, Int> {
        val out = LinkedHashMap<String, Int>()
        try {
            val root = Class.forName(ROOT)
            collectIntFields(root, "", out)
            // Walk nested classes (BYD groups some IDs into nested
            // categories: Safety, Setting, Bodywork, etc.). Each
            // entry is stored TWICE — once bare (`X`) and once
            // prefixed (`Setting.X`). Bare keeps the textproto's
            // legacy entries that pre-date the prefix migration
            // working; prefixed disambiguates collisions across
            // groups (e.g. root.X vs Safety.X with different ints).
            // The migration tool that rewrote `key: <hex>` →
            // `feature_name: "..."` emits the prefixed form for any
            // catalog entry whose canonical name comes from a
            // nested class.
            for (nested in root.declaredClasses) {
                try {
                    val prefix = nested.simpleName + "."
                    collectIntFields(nested, prefix, out)
                    // Also store bare (no prefix) — back-compat for
                    // any pre-migration textproto entries that used
                    // the unprefixed name.
                    collectIntFields(nested, "", out)
                } catch (t: Throwable) {
                    Log.i(TAG, "skip nested ${nested.simpleName}: ${t.javaClass.simpleName}")
                }
            }
            Log.i(TAG, "loaded ${out.size} feature IDs from $ROOT")
        } catch (t: Throwable) {
            // Expected on user-app installs where the framework jar is
            // not on the classloader. Returns an empty catalog; callers
            // gracefully degrade.
            Log.i(TAG, "framework catalog unavailable: ${t.javaClass.simpleName}")
        }
        return out
    }

    private fun collectIntFields(
        cls: Class<*>,
        prefix: String,
        out: MutableMap<String, Int>,
    ) {
        for (field in cls.declaredFields) {
            val mods = field.modifiers
            if (!java.lang.reflect.Modifier.isStatic(mods) ||
                !java.lang.reflect.Modifier.isFinal(mods) ||
                field.type != Int::class.javaPrimitiveType
            ) continue
            try {
                field.isAccessible = true
                // Don't overwrite an existing entry with a different
                // int — the FIRST registration wins, so the bare-name
                // version (added before nested walk) takes precedence
                // for any name that exists in both root and nested.
                val key = prefix + field.name
                if (key !in out) {
                    out[key] = field.getInt(null)
                }
            } catch (t: Throwable) {
                // Skip fields that reflect-fail. Field-level isolation
                // means one stripped constant doesn't drop the rest.
            }
        }
    }
}

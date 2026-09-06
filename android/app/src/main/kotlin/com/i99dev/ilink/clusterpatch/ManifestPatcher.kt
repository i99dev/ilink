package com.i99dev.ilink.clusterpatch

import com.reandroid.apk.ApkModule
import com.reandroid.arsc.chunk.xml.AndroidManifestBlock
import com.reandroid.arsc.chunk.xml.ResXmlElement
import com.reandroid.arsc.value.ValueType

/**
 * Applies the BYD-cluster-enabling delta to a target app's **base**
 * AndroidManifest, in-place on an [ApkModule]. This is the only manifest
 * mutation the patcher performs; everything else (sign / stage / install)
 * is mechanical.
 *
 * ## Ground truth
 * The exact delta was decompiled from the reference (
 * obfuscated class `Loa`) — see `docs/plans/CLUSTER_APP_PATCHER_PLAN.md`.
 * DiLink does NOT honour `resizeableActivity` alone for cluster / split
 * placement; the `BYD_SUPPORT_SPLIT_ACTIVITY` `<meta-data>` is the vendor
 * whitelist marker the BYD window manager reads. Both are required.
 *
 * Attribute resource ids are the AOSP framework ids (verified against
 * `platforms/android-36/data/res/values/public-final.xml`), NOT guessed:
 *   * `resizeableActivity` = 0x010104f6
 *   * `extractNativeLibs`  = 0x010104ea  (ARSCLib [AndroidManifestBlock.ID_extractNativeLibs])
 *   * `name`               = 0x01010003  (ARSCLib [AndroidManifestBlock.ID_name])
 *   * `value`              = 0x01010024  (ARSCLib [AndroidManifestBlock.ID_value])
 */
object ManifestPatcher {

    /** AOSP `android:resizeableActivity` attribute resource id. ARSCLib has
     *  no constant for it, so it's pinned here from the platform's
     *  `public-final.xml` (0x010104f6 — note: NOT 0x0101053b, a value some
     *  third-party references cite incorrectly). */
    const val ID_resizeableActivity: Int = 0x010104f6

    /** The BYD DiLink whitelist marker. The WMS reads this `<meta-data>` on
     *  `<application>` to allow the app onto a secondary / cluster display.
     *  Value is the integer `1` (TYPE_INT_DEC), faithful to the reference. */
    const val BYD_SUPPORT_META_NAME: String = "BYD_SUPPORT_SPLIT_ACTIVITY"

    /**
     * Mutate [module]'s base manifest with the cluster delta:
     *  1. `android:resizeableActivity="true"` on `<application>`
     *  2. inject `<meta-data android:name="BYD_SUPPORT_SPLIT_ACTIVITY"
     *     android:value="1"/>` (skipped if already present — idempotent)
     *  3. `android:extractNativeLibs="true"` — a re-zipped APK can't
     *     guarantee uncompressed-`.so` page alignment, so force extract.
     *
     * The caller is responsible for [ApkModule.refreshManifest] +
     * [ApkModule.writeApk] to persist.
     */
    fun applyClusterDelta(module: ApkModule) {
        val manifest: AndroidManifestBlock = module.androidManifest
        val application: ResXmlElement = manifest.orCreateApplicationElement

        application.getOrCreateAndroidAttribute("resizeableActivity", ID_resizeableActivity)
            .setValueAsBoolean(true)

        application.getOrCreateAndroidAttribute(
            "extractNativeLibs",
            AndroidManifestBlock.ID_extractNativeLibs,
        ).setValueAsBoolean(true)

        // Inject <meta-data android:name="BYD_SUPPORT_SPLIT_ACTIVITY"
        // android:value="1"/>. Idempotency (don't patch an already-patched
        // package, which would duplicate this element) is enforced one
        // layer up by the PatchRegistry (M2) — keyed on the installed
        // signer + a stored marker version — so this stays a pure inject.
        val meta = application.createChildElement("meta-data")
        meta.getOrCreateAndroidAttribute("name", AndroidManifestBlock.ID_name)
            .setValueAsString(BYD_SUPPORT_META_NAME)
        meta.getOrCreateAndroidAttribute("value", AndroidManifestBlock.ID_value)
            .setTypeAndData(ValueType.DEC, 1)
        // Note: extractNativeLibs is set as a manifest attribute above; the
        // loader honours that at install time, so the re-zipped APK needn't
        // satisfy the uncompressed-.so page-alignment requirement.
    }
}

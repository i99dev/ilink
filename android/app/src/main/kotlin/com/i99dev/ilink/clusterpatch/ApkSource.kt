package com.i99dev.ilink.clusterpatch

import android.content.Context
import android.content.pm.PackageManager
import java.io.File

/**
 * Resolves an installed package's on-disk APK set (base + config splits)
 * and the inputs the patch pipeline needs. Reads `ApplicationInfo`
 * directly — third-party `/data/app/**/base.apk` files are world-readable
 * (0644), so the app process can read them without the shell bridge, the
 * same way the reference does.
 */
object ApkSource {

    data class ApkSet(
        val packageName: String,
        val base: File,
        val splits: List<File>,
        val minSdk: Int,
        val versionCode: Long,
    )

    /** @throws PackageManager.NameNotFoundException if [packageName] is gone. */
    fun resolve(context: Context, packageName: String): ApkSet {
        val pm = context.packageManager
        val ai = pm.getApplicationInfo(packageName, 0)
        val base = File(ai.sourceDir)
        val splits = ai.splitSourceDirs?.map(::File) ?: emptyList()
        // minSdkVersion is available since API 24; some system apps report
        // 0 — fall back to a safe floor so apksig still picks a valid scheme.
        val minSdk = ai.minSdkVersion.takeIf { it > 0 } ?: 24
        val pkgInfo = pm.getPackageInfo(packageName, 0)
        @Suppress("DEPRECATION")
        val versionCode = pkgInfo.longVersionCode
        return ApkSet(packageName, base, splits, minSdk, versionCode)
    }
}

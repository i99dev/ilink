package com.i99dev.ilink.ota

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/**
 * Method-channel surface for the OTA update flow:
 *   - checkApkSigner(apkPath)    → {ok: Bool, expected: String, actual: String}
 *   - canInstallPackages()       → Bool
 *   - openInstallSettings()      → void
 *   - installApk(path)           → void
 */
class OtaChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "ilink/ota")

    fun register() {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "checkApkSigner" -> {
                        val path = call.argument<String>("apkPath") ?: ""
                        result.success(checkApkSigner(path))
                    }
                    "canInstallPackages" -> {
                        result.success(canInstallPackages())
                    }
                    "openInstallSettings" -> {
                        openInstallSettings()
                        result.success(null)
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path") ?: ""
                        installApk(path)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                Log.w(TAG, "${call.method} failed: ${t.message}")
                result.error("OTA_ERROR", t.message, null)
            }
        }
    }

    private fun checkApkSigner(apkPath: String): Map<String, Any> {
        val configuredSigner = android.os.Build.VERSION.SDK_INT.let {
            // EXPECTED_SIGNER_SHA is injected at build time via BuildConfig.
            com.i99dev.ilink.BuildConfig.EXPECTED_SIGNER_SHA
        }

        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }

        val pm = context.packageManager
        // Community builds pin updates to their own installed certificate when
        // no release pin was configured. An empty pin must never mean any signer.
        val expected = configuredSigner.ifBlank {
            runCatching {
                @Suppress("DEPRECATION")
                val installed = pm.getPackageInfo(context.packageName, flags)
                val cert = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    installed.signingInfo?.signingCertificateHistory?.firstOrNull()
                } else {
                    @Suppress("DEPRECATION")
                    installed.signatures?.firstOrNull()
                }
                cert?.toByteArray()?.let {
                    MessageDigest.getInstance("SHA-256").digest(it)
                        .joinToString("") { byte -> "%02x".format(byte) }
                }.orEmpty()
            }.getOrDefault("")
        }
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageArchiveInfo(apkPath, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageArchiveInfo(apkPath, flags)
        } ?: return mapOf("ok" to false, "expected" to expected, "actual" to "(parse failed)")

        val certBytes: ByteArray? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.signingCertificateHistory?.firstOrNull()?.toByteArray()
        } else {
            @Suppress("DEPRECATION")
            info.signatures?.firstOrNull()?.toByteArray()
        }

        if (certBytes == null) {
            return mapOf("ok" to false, "expected" to expected, "actual" to "(no cert)")
        }

        // Render the actual cert SHA as plain lowercase hex. The
        // previous keytool-style `AB:CD:EF:...` formatting never
        // matched BuildConfig.EXPECTED_SIGNER_SHA which is injected
        // by CI in bare hex (`2a4700...`). Compare both sides after
        // stripping `:` and lowercasing — an operator who pastes
        // either format into the env var still validates.
        val actual = MessageDigest.getInstance("SHA-256")
            .digest(certBytes)
            .joinToString("") { "%02x".format(it) }

        fun norm(s: String) = s.replace(":", "").lowercase()
        val ok = expected.isNotBlank() && norm(actual) == norm(expected) &&
            info.packageName == context.packageName
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        return mapOf(
            "ok" to ok, "expected" to expected, "actual" to actual,
            "packageName" to info.packageName, "versionCode" to versionCode,
        )
    }

    private fun canInstallPackages(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                data = Uri.parse("package:${context.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        }
    }

    /**
     * Install the downloaded APK via the [PackageInstaller] Session API.
     *
     * We deliberately do NOT use ACTION_INSTALL_PACKAGE + FileProvider: that path
     * depends on a manifest `<meta-data android:resource="@xml/ota_file_paths">`,
     * and the release resource-shrinker strips that xml (it's only reachable from
     * manifest meta-data, which the shrinker doesn't trace) — blanking the resource
     * so FileProvider throws "Missing android.support.FILE_PROVIDER_PATHS meta-data"
     * and EVERY OTA self-install fails (root-caused on-car 2026-06-27). The session
     * API streams the bytes directly and needs no FileProvider/resource at all.
     *
     * commit() raises STATUS_PENDING_USER_ACTION → [installReceiver] launches the
     * system "install this update?" confirmation. Requires REQUEST_INSTALL_PACKAGES
     * (already gated by [canInstallPackages]).
     */
    private fun installApk(apkPath: String) {
        val file = File(apkPath)
        if (!file.exists() || file.length() == 0L) {
            throw IllegalStateException("OTA apk missing/empty: $apkPath")
        }
        ensureInstallReceiver()
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL,
        )
        // Self-update hint (same package); harmless if the platform ignores it.
        runCatching { params.setAppPackageName(context.packageName) }
        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
            file.inputStream().use { input ->
                session.openWrite("ota.apk", 0, file.length()).use { out ->
                    input.copyTo(out, bufferSize = 1 shl 16)
                    session.fsync(out)
                }
            }
            val statusIntent = Intent(INSTALL_STATUS_ACTION).setPackage(context.packageName)
            val piFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pi = PendingIntent.getBroadcast(context, sessionId, statusIntent, piFlags)
            session.commit(pi.intentSender)
        }
    }

    /** Registers (once) the receiver that turns a PackageInstaller
     *  STATUS_PENDING_USER_ACTION into the system install-confirm screen. */
    private fun ensureInstallReceiver() {
        if (installReceiverRegistered) return
        val filter = IntentFilter(INSTALL_STATUS_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(installReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(installReceiver, filter)
        }
        installReceiverRegistered = true
    }

    @Volatile private var installReceiverRegistered = false

    private val installReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, Int.MIN_VALUE)) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                    }
                    confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    runCatching { ctx.startActivity(confirm) }
                        .onFailure { Log.w(TAG, "launch install-confirm failed: ${it.message}") }
                }
                PackageInstaller.STATUS_SUCCESS ->
                    Log.i(TAG, "OTA install succeeded")
                else -> {
                    val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                    Log.w(TAG, "OTA install status=$status msg=$msg")
                }
            }
        }
    }

    companion object {
        private const val TAG = "OtaChannel"
        private const val INSTALL_STATUS_ACTION = "com.i99dev.ilink.OTA_INSTALL_STATUS"
    }
}

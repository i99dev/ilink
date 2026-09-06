package com.i99dev.ilink.adb

import android.content.Context
import android.util.Base64
import android.util.Log
import com.i99dev.ilink.BuildConfig
import com.i99dev.ilink.security.CryptoUtils
import com.i99dev.ilink.security.DeviceKeyMaterial
import com.i99dev.ilink.security.EncryptedAssetLoader
import org.json.JSONObject
import java.io.File

/**
 * Stages unit DEX files into `/data/local/tmp/` so `app_process64` can
 * find them when `UnitDispatcher` runs a UNIT_ACTIONS entry.
 *
 * Public offline assets are the default: offline/units/manifest.json and
 * plaintext DEX files are covered by the APK signature and verified by SHA-256.
 * Legacy modes:
 *   - **Encrypted ship-in-APK.** When `assets/units/manifest.json` + the
 *     `assets/units/{name}.dex.enc` blobs are present, the stager decrypts
 *     each entry, verifies SHA-256 against the manifest, and writes it to
 *     `/data/local/tmp/<name>.dex`. Re-staging only happens when the
 *     on-disk SHA differs from the manifest — matches the integrity gate
 *     described in the plan (Phase 4).
 *   - **Pre-staged (current behaviour).** When the encrypted assets are
 *     absent, the stager is a no-op. Whoever provisioned the head unit is
 *     responsible for having dropped the DEX files under `/data/local/tmp/`
 *     themselves. Dash keeps working.
 *
 * The asset tree is added by the CI pipeline once the private
 * `byd-dash-secrets` repo is set up; no code change is required to flip
 * from pre-staged to encrypted — shipping the manifest is the switch.
 *
 * Manifest shape (JSON today; proto when codegen lands):
 * ```
 * {
 *   "units": [
 *     { "name": "doorunit.dex",   "sha256": "<hex>" },
 *     { "name": "acunit.dex",     "sha256": "<hex>" }
 *   ]
 * }
 * ```
 */
object UnitDexStager {
    private const val TAG = "UnitDexStager"
    private const val MANIFEST_ASSET = "units/manifest.json"
    private const val LOCAL_MANIFEST_ASSET = "offline/units/manifest.json"
    private const val ASSET_PREFIX = "units/"
    private const val ENC_SUFFIX = ".enc"
    private const val STAGE_DIR = "/data/local/tmp"

    /**
     * @return `true` if every declared unit is present on disk and
     *         integrity-verified, OR if no manifest exists in a debug
     *         build (pre-staged mode is dev-only convenience).
     *         `false` when:
     *           * the manifest exists but at least one unit can't be
     *             staged (release: don't start the daemon — it would
     *             return ``unknown action`` for every unit_action), OR
     *           * we're a release build and the manifest is missing
     *             entirely (the public offline assets were not packaged
     *             — fail loud rather than silently boot a build that
     *             will appear to work but fail every seat / fragrance /
     *             atmos / find-car command at runtime).
     *
     * Pre-staged mode (no manifest) only stays a no-op in DEBUG builds
     * so emulators / dev installs without the unit-source repo can
     * still boot and exercise everything except unit_action commands.
     */
    fun stageAllIfNeeded(context: Context): Boolean {
        val manifest = readManifestOrNull(context) ?: run {
            if (BuildConfig.DEBUG) {
                Log.i(TAG, "no manifest — pre-staged mode, skipping (debug build)")
                return true
            }
            // Missing public offline unit metadata means an incomplete build.
            // Keep unrelated local features available and report degraded
            // unit dispatch instead of silently treating staging as complete.
            Log.e(
                TAG,
                "FATAL: no units/manifest.json in release build — every " +
                    "unit_action in car_table (seat heat/vent, fragrance, " +
                    "atmos, light flash, find_car) WILL fail at the daemon. " +
                    "Package the checked-in offline unit manifest and DEX assets " +
                    "before assembling the release APK.",
            )
            return false
        }

        // Public units are protected by the APK signature and manifest hashes.
        // Derive a key only for older encrypted bundles; no server is involved.
        val key = if (manifest.any { it.encrypted }) {
            DeviceKeyMaterial.fromContext(context).deriveReleaseKey()
        } else null

        var allOk = true
        for (entry in manifest) {
            val ok = stageOne(context, entry, key)
            if (!ok) allOk = false
        }
        return allOk
    }

    private fun stageOne(
        context: Context,
        entry: UnitEntry,
        key: javax.crypto.SecretKey?,
    ): Boolean {
        val dest = File(STAGE_DIR, entry.name)
        val expected = hexToBytes(entry.sha256)

        // Happy path: already on disk with the right SHA. Skip the decrypt
        // + write cost, which also spares us needless FS churn.
        if (dest.exists()) {
            val actual = CryptoUtils.sha256(dest.readBytes())
            if (actual.contentEquals(expected)) return true
            Log.w(TAG, "${entry.name}: on-disk SHA mismatch, re-staging")
        }

        val plaintext = try {
            if (entry.encrypted) {
                EncryptedAssetLoader.loadOrNull(context, ASSET_PREFIX + entry.name + ENC_SUFFIX, requireNotNull(key))
            } else {
                context.assets.open("offline/units/${entry.name}").use { it.readBytes() }
            }
        } catch (e: Throwable) {
            Log.e(TAG, "${entry.name}: decrypt failed: ${e.message}")
            return false
        }
        if (plaintext == null) {
            Log.e(TAG, "${entry.name}: manifest declared but encrypted asset missing")
            return false
        }
        val plaintextSha = CryptoUtils.sha256(plaintext)
        if (!plaintextSha.contentEquals(expected)) {
            Log.e(TAG, "${entry.name}: decrypted SHA mismatch — refusing to stage")
            return false
        }
        // Write via adb-shell loopback: /data/local/tmp is shell:shell 0771
        // so the dash app UID can't write directly (EACCES). The loopback
        // adbd session runs commands as shell UID — we pipe base64 of the
        // plaintext to `base64 -d > /data/local/tmp/<name>.dex` and the
        // file lands owned by shell with default 0644 perms (app can read,
        // shell can execute via app_process64). Base64 expands ~4/3×; our
        // DEX files are <10 KB each so each command is <15 KB, well under
        // ARG_MAX (usually ≥128 KB). No single-quote escape issues because
        // base64 alphabet is A-Za-z0-9+/=.
        val b64 = Base64.encodeToString(plaintext, Base64.NO_WRAP)
        val cmd = "printf '%s' '$b64' | base64 -d > /data/local/tmp/${entry.name}"
        val out = AdbShellBridge.shell(cmd, timeoutMs = 10_000)
        if (out.startsWith("Error:")) {
            Log.e(TAG, "${entry.name}: shell write failed: $out")
            return false
        }
        // Verify the write round-trips — SHA of what ended up on disk must
        // match the manifest. Catches partial writes, truncated base64,
        // and any quiet silent corruption mid-pipe.
        if (!dest.exists()) {
            Log.e(TAG, "${entry.name}: shell write reported ok but file missing")
            return false
        }
        val verifySha = CryptoUtils.sha256(dest.readBytes())
        if (!verifySha.contentEquals(expected)) {
            Log.e(TAG, "${entry.name}: post-write SHA mismatch — attempted clean")
            AdbShellBridge.shell("rm -f /data/local/tmp/${entry.name}", timeoutMs = 3_000)
            return false
        }
        Log.i(TAG, "${entry.name}: staged ${plaintext.size} B via shell loopback")
        return true
    }

    private data class UnitEntry(val name: String, val sha256: String, val encrypted: Boolean)

    private fun readManifestOrNull(context: Context): List<UnitEntry>? {
        return try {
            val local = context.assets.list("offline/units")?.contains("manifest.json") == true
            val raw = context.assets.open(if (local) LOCAL_MANIFEST_ASSET else MANIFEST_ASSET).use {
                it.readBytes().toString(Charsets.UTF_8)
            }
            val units = JSONObject(raw).getJSONArray("units")
            buildList {
                for (i in 0 until units.length()) {
                    val u = units.getJSONObject(i)
                    val name = u.getString("name")
                    val hash = u.getString("sha256")
                    // Names enter a shell command below; accept simple DEX basenames only.
                    require(Regex("[A-Za-z0-9_-]+\\.dex").matches(name))
                    require(Regex("[a-fA-F0-9]{64}").matches(hash))
                    add(UnitEntry(name, hash, encrypted = !local))
                }
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun hexToBytes(hex: String): ByteArray {
        require(hex.length % 2 == 0) { "odd-length hex: $hex" }
        val out = ByteArray(hex.length / 2)
        for (i in out.indices) {
            out[i] = ((hex[i * 2].digitToInt(16) shl 4) or hex[i * 2 + 1].digitToInt(16)).toByte()
        }
        return out
    }
}

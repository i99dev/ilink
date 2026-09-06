package com.i99dev.ilink.clusterpatch

import android.util.Base64
import android.util.Log
import com.i99dev.ilink.adb.AdbShellBridge
import java.io.File
import java.io.InputStream
import java.security.MessageDigest

/**
 * Installs a patched APK set by **replacing** the original, entirely over
 * the loopback-ADB shell bridge (shell uid). The recipe was proven on
 * AAOS_DiLink_A13 before being encoded here:
 *
 *  1. base64-stage each apk to `/data/local/tmp` (shell:shell 0644 — the
 *     app can't write there directly, but the bridge runs as shell). We
 *     append the base64 **text** in chunks (each shell command must stay
 *     under the ~128 KB per-arg cap) then `base64 -d` the whole file once,
 *     which is split-safe. SHA-256 round-trip verified.
 *  2. `pm uninstall` the original — a different signer (our reused key)
 *     makes in-place replacement impossible, so the original must go first.
 *     App data is reset; this is surfaced in the consent dialog (M4).
 *  3. `pm install-create -t -r` → write each apk via the **stdin** form
 *     (`cat staged.apk | pm install-write -S <size> <sid> <name> -`; the
 *     path form fell back to stdin and staged nothing) → `install-commit`.
 *
 * Pure helpers ([parseSessionId], [isSuccess], [chunkText]) are extracted
 * for host unit tests; the shell-bound steps are validated on-device.
 */
object PrivilegedApkInstaller {
    private const val TAG = "ClusterPatchInstall"
    private const val STAGE_DIR = "/data/local/tmp"

    /** RAW bytes per staged block — a multiple of 3 so each block's base64
     *  has no padding and the appended pieces concatenate into one decodable
     *  stream. base64 of 60 KB = 80 KB, under Android's ~128 KB per-arg cap
     *  (MAX_ARG_STRLEN). Streaming at this granularity keeps memory flat
     *  regardless of APK size (a 157 MB APK OOM'd the old whole-file base64). */
    private const val RAW_CHUNK = 60 * 1024

    /** Max APK size for the binary push fast path. adbd's `exec:cat` stream
     *  deterministically stalls past ~60 MB on this path (its flow-control
     *  window isn't fully handled yet), so above this we go straight to
     *  base64. Covers the vast majority of apps; SHA-verify + base64 fallback
     *  keep even a gate miss fail-safe. */
    private const val PUSH_MAX_BYTES = 45L * 1024 * 1024

    /** Functional shell shape — `AdbShellBridge::shell` in production, a
     *  recording stub in tests. */
    private val DEFAULT_SHELL: (String, Long) -> String = AdbShellBridge::shell

    /** Functional binary-push shape — `AdbShellBridge.pushFile` (a dedicated
     *  adb connection so it never holds the bridge lock). ENABLED but capped at
     *  [PUSH_MAX_BYTES]: fast for the vast majority of apps, and fully fail-safe
     *  — SHA-verify after the push + base64 fallback means a bad/stalled push
     *  can't corrupt or hang anything. Genuinely huge APKs (> the cap) skip
     *  straight to base64 until adbd's delayed-ack flow-control windowing is
     *  implemented (the push stalls past ~60 MB) and verified on a real car. */
    private val DEFAULT_PUSH: (File, String) -> Boolean = { f, p -> AdbShellBridge.pushFile(f, p) }

    sealed interface Result {
        object Ok : Result
        /** [stage] ∈ {stage, create, write, commit}; [detail] is the shell tail. */
        data class Failed(val stage: String, val detail: String) : Result
    }

    /**
     * Replace [packageName] with the patched [base] (+ [splits]). Returns
     * [Result.Ok] on a committed install. Staged temp files are always
     * cleaned up.
     */
    fun replaceInstall(
        packageName: String,
        base: File,
        splits: List<File>,
        shell: (String, Long) -> String = DEFAULT_SHELL,
        push: (File, String) -> Boolean = DEFAULT_PUSH,
    ): Result {
        val staged = mutableListOf<String>()
        try {
            val baseRemote = stage(base, "i99p_${packageName}_base.apk", shell, push)
                ?: return Result.Failed("stage", "base staging/sha failed")
            staged += baseRemote
            val splitRemotes = ArrayList<String>(splits.size)
            splits.forEachIndexed { i, f ->
                val r = stage(f, "i99p_${packageName}_split_$i.apk", shell, push)
                    ?: return Result.Failed("stage", "split $i staging/sha failed")
                staged += r; splitRemotes += r
            }

            // Replace model: drop the original (different signer) first.
            shell("pm uninstall $packageName", 30_000L)

            val createOut = shell("pm install-create -t -r", 15_000L)
            val sid = parseSessionId(createOut)
                ?: return Result.Failed("create", createOut.take(200))

            writeApk(sid, "base", base.length(), baseRemote, shell)
                ?.let { return Result.Failed("write", it) }
            splitRemotes.forEachIndexed { i, remote ->
                writeApk(sid, "split_$i", splits[i].length(), remote, shell)
                    ?.let { return Result.Failed("write", it) }
            }

            val commitOut = shell("pm install-commit $sid", 60_000L)
            return if (isSuccess(commitOut)) Result.Ok
            else Result.Failed("commit", commitOut.take(200))
        } finally {
            if (staged.isNotEmpty()) {
                shell("rm -f " + staged.joinToString(" "), 10_000L)
            }
        }
    }

    /**
     * Stage [local] to `$STAGE_DIR/$remoteName`; returns the remote path on a
     * SHA-verified round-trip, else null.
     *
     * Fast path: a **binary push** (raw bytes over the adb stream — orders of
     * magnitude faster on large APKs). If the push is unavailable or its bytes
     * don't verify, fall back to the **base64-over-shell** stream (per-block,
     * padding-free, constant memory). The SHA check after EITHER path makes a
     * bad transfer fail safely (the caller's replace never uninstalls the
     * original until every stage verifies).
     */
    private fun stage(
        local: File,
        remoteName: String,
        shell: (String, Long) -> String,
        push: (File, String) -> Boolean,
    ): String? {
        val remote = "$STAGE_DIR/$remoteName"
        val want = sha256Hex(local)

        shell("rm -f $remote", 5_000L)
        // Fast path: binary push, but only up to PUSH_MAX_BYTES (the stream
        // stalls past ~60 MB). Above the gate, skip straight to base64.
        if (local.length() <= PUSH_MAX_BYTES &&
            push(local, remote) &&
            shaOk(remote, want, shell)
        ) {
            return remote
        }

        Log.i(TAG, "$remoteName: base64 staging")
        shell("rm -f $remote", 5_000L)
        if (base64Stream(local, remote, shell) && shaOk(remote, want, shell)) return remote

        Log.e(TAG, "$remoteName: staging failed (push + base64)")
        return null
    }

    /** base64-over-shell stream: decode each [RAW_CHUNK] block independently
     *  (`printf '%s' '<b64>' | base64 -d >> file`, the UnitDexStager-proven
     *  shape) and append its raw bytes. Each block is a multiple of 3 bytes
     *  (bar the last) so its base64 is padding-free and concatenates cleanly.
     *  Constant memory regardless of APK size. */
    private fun base64Stream(local: File, remote: String, shell: (String, Long) -> String): Boolean {
        val buf = ByteArray(RAW_CHUNK)
        var first = true
        try {
            local.inputStream().buffered().use { ins ->
                while (true) {
                    val n = fill(ins, buf)
                    if (n == 0) break
                    val b64 = Base64.encodeToString(buf, 0, n, Base64.NO_WRAP)
                    val redir = if (first) ">" else ">>"
                    val out = shell("printf '%s' '$b64' | base64 -d $redir $remote", 30_000L)
                    if (out.startsWith("Error:")) {
                        Log.e(TAG, "stage chunk failed: ${out.take(120)}")
                        return false
                    }
                    first = false
                    if (n < buf.size) break // last (short) block — EOF
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "base64 stream failed: ${t.message}")
            return false
        }
        return true
    }

    /** SHA-256 (hex) of a local file, streamed (constant memory). */
    private fun sha256Hex(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buf = ByteArray(64 * 1024)
        file.inputStream().buffered().use { ins ->
            while (true) {
                val n = ins.read(buf)
                if (n < 0) break
                digest.update(buf, 0, n)
            }
        }
        return toHex(digest.digest())
    }

    /** True if the device file at [remote] has SHA-256 == [want]. */
    private fun shaOk(remote: String, want: String, shell: (String, Long) -> String): Boolean {
        val got = shell("sha256sum $remote", 30_000L).trim().substringBefore(' ')
        val ok = got.equals(want, ignoreCase = true)
        if (!ok) Log.w(TAG, "$remote: sha mismatch want=$want got=$got")
        return ok
    }

    /** Fully fill [buf] from [ins], tolerating short reads; the returned count
     *  is < [buf].size only at EOF — so every block but the last is exactly
     *  [RAW_CHUNK] (a multiple of 3, hence padding-free base64). */
    private fun fill(ins: InputStream, buf: ByteArray): Int {
        var off = 0
        while (off < buf.size) {
            val n = ins.read(buf, off, buf.size - off)
            if (n < 0) break
            off += n
        }
        return off
    }

    /** stdin-form install-write (the proven reliable form). Returns null on
     *  success, else the failure tail. */
    private fun writeApk(
        sessionId: Int,
        splitName: String,
        size: Long,
        remote: String,
        shell: (String, Long) -> String,
    ): String? {
        val out = shell("cat $remote | pm install-write -S $size $sessionId $splitName -", 120_000L)
        return if (isSuccess(out)) null else out.take(200)
    }

    // ---- pure, host-unit-testable helpers ----

    /** Session id from `Success: created install session [N]`. */
    internal fun parseSessionId(out: String): Int? =
        Regex("\\[(\\d+)]").find(out)?.groupValues?.getOrNull(1)?.toIntOrNull()

    /** A `pm` command succeeded: says "Success" and not "Failure". */
    internal fun isSuccess(out: String): Boolean =
        out.contains("Success", ignoreCase = true) && !out.contains("Failure", ignoreCase = true)

    /** Split [s] into ≤[size]-char pieces (single piece when it already fits). */
    internal fun chunkText(s: String, size: Int): List<String> =
        if (s.length <= size) listOf(s) else s.chunked(size)

    private fun toHex(bytes: ByteArray): String {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) sb.append("%02x".format(b.toInt() and 0xff))
        return sb.toString()
    }
}

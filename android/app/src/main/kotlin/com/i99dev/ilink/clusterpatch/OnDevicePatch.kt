package com.i99dev.ilink.clusterpatch

import java.io.File

/**
 * On-device patcher entry point — runs as **shell uid** via
 * `app_process64 -cp <our.apk> com.i99dev.ilink.clusterpatch.OnDevicePatchKt …`.
 *
 * Why: the round-trip patcher ([PrivilegedApkInstaller]) ships the whole
 * re-signed APK set (Waze ≈ 189 MB) back to the device over the ADB stream —
 * minutes for a large app. This runs the SAME [ClusterApkPatcher] (ARSCLib +
 * apksig) where the data already lives: it reads the originals straight from
 * `/data/app`, patches + re-signs into `/data/local/tmp` (local I/O), and
 * `pm install`s from there. Nothing big crosses the connection — the app only
 * sends this command + paths and reads back a one-line result. This is how
 * the reference's privileged proxy does it.
 *
 * Output protocol (last line): `I99_PATCH_OK` / `I99_UNPATCH_OK` /
 * `I99_UNPATCH_REMOVED` / `I99_PATCH_FAILED:<reason>`.
 */
fun main(args: Array<String>) {
    try {
        when (args.getOrNull(0)) {
            "signer" -> println("I99_PATCH_SIGNER:${PatchSigner.certificateSha256()}")
            "patch" -> patch(args)
            "unpatch" -> unpatch(args)
            else -> println("I99_PATCH_FAILED:bad-op")
        }
    } catch (t: Throwable) {
        println("I99_PATCH_FAILED:${t.javaClass.simpleName}:${t.message}")
    }
}

private val TMP = File("/data/local/tmp")

// patch <pkg> <minSdk> <baseApk> [splitApk...]
private fun patch(args: Array<String>) {
    val pkg = args[1]
    val minSdk = args[2].toInt()
    val base = File(args[3])
    val splits = args.drop(4).map { File(it) }

    val work = File(TMP, "i99p_$pkg").apply { deleteRecursively(); mkdirs() }
    val backup = File(TMP, "i99p_bak/$pkg")
    try {
        // 1) Back up the originals ONLY if we don't already have a good backup.
        //    On a re-patch the source `base`/`splits` are the ALREADY-PATCHED
        //    APKs (ApkSource reads the installed sourceDir); overwriting the
        //    backup then would destroy the only pristine copy. unpatch() deletes
        //    the backup, so the first patch after an unpatch backs up fresh.
        if (!File(backup, "base.apk").exists()) {
            backup.deleteRecursively(); backup.mkdirs()
            base.copyTo(File(backup, "base.apk"), overwrite = true)
            splits.forEachIndexed { i, f -> f.copyTo(File(backup, "split_$i.apk"), overwrite = true) }
        }

        // 2) patch + re-sign locally (ARSCLib + apksig) into /data/local/tmp
        val patched = ClusterApkPatcher.patch(base, splits, work, minSdk)

        // 3) install from local files — no transfer. On failure AFTER the
        //    uninstall, roll the original back from the local backup so a failed
        //    patch never leaves the app uninstalled (bricked). If the restore
        //    ALSO fails, say so distinctly so the user can recover.
        try {
            installSet(pkg, patched.base, patched.splits)
        } catch (t: Throwable) {
            val restored = runCatching { restoreFromBackup(pkg, backup) }.isSuccess
            if (!restored) {
                println("I99_PATCH_FAILED_APP_REMOVED:${t.message}")
                return
            }
            throw t
        }
        println("I99_PATCH_OK")
    } finally {
        work.deleteRecursively()
    }
}

/** Reinstall the original parts from [backup] (rollback / undo). */
private fun restoreFromBackup(pkg: String, backup: File) {
    val base = File(backup, "base.apk")
    if (!base.exists()) return
    val splits = (backup.listFiles { f -> f.name.startsWith("split_") } ?: emptyArray())
        .sortedBy { it.name }
    installParts(pkg, base, splits)
}

// unpatch <pkg> — restore the backed-up originals, else just remove
private fun unpatch(args: Array<String>) {
    val pkg = args[1]
    val backup = File(TMP, "i99p_bak/$pkg")
    val base = File(backup, "base.apk")
    if (!base.exists()) {
        sh("pm uninstall --user current $pkg")
        println("I99_UNPATCH_REMOVED")
        return
    }
    val splits = (backup.listFiles { f -> f.name.startsWith("split_") } ?: emptyArray()).sortedBy { it.name }
    installSet(pkg, base, splits)
    backup.deleteRecursively()
    println("I99_UNPATCH_OK")
}

private fun installSet(pkg: String, base: File, splits: List<File>) {
    // Close the app first — a cluster-cast attempt may have just launched it,
    // and uninstalling/reinstalling a RUNNING app is unsafe (stale process,
    // file locks). force-stop kills it before we replace it.
    sh("am force-stop $pkg")
    // --user current: uninstall + reinstall for the SAME (foreground/driver)
    // user. Without it, `pm uninstall` drops all users but `pm install-create`
    // installs only user 0 → the app vanishes for a non-0 driver (multi-user AAOS).
    sh("pm uninstall --user current $pkg")
    installParts(pkg, base, splits)
}

/** The session install (create → write each part → commit). The caller has
 *  already force-stopped + uninstalled. Used for both the patched set and the
 *  rollback/restore of the original. */
private fun installParts(pkg: String, base: File, splits: List<File>) {
    val createOut = sh("pm install-create -t -r --user current")
    val sid = Regex("""\[(\d+)\]""").find(createOut)?.groupValues?.get(1)
        ?: error("install-create: ${createOut.take(120)}")
    try {
        writePart(sid, "base", base)
        splits.forEachIndexed { i, f -> writePart(sid, "split_$i", f) }
        val commit = sh("pm install-commit $sid")
        if (!commit.contains("Success")) error("commit: ${commit.take(160)}")
    } catch (t: Throwable) {
        sh("pm install-abandon $sid")
        throw t
    }
}

private fun writePart(sid: String, name: String, f: File) {
    // stdin form is the proven-reliable one; the cat is LOCAL so it's fast.
    val out = sh("cat '${f.absolutePath}' | pm install-write -S ${f.length()} $sid $name -")
    if (out.contains("Failure") || out.contains("Error")) error("write $name: ${out.take(160)}")
}

private fun sh(cmd: String): String {
    val p = ProcessBuilder("sh", "-c", cmd).redirectErrorStream(true).start()
    val out = p.inputStream.bufferedReader().readText()
    p.waitFor()
    return out
}

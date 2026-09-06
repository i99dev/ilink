package com.i99dev.ilink.display

import java.io.File
import java.net.URI

/** Offline visual surfaces have no host bridge and can read only their own bundle. */
internal class SecondarySurfacePolicy(bundleUri: String) {
    private val entry = localFile(bundleUri)
    private val root = requireNotNull(entry.parentFile).canonicalFile

    fun requireOwner(filesDir: File, appId: String) {
        require(appId.matches(Regex("[A-Za-z0-9][A-Za-z0-9._-]*"))) { "Invalid app id" }
        val appRoot = File(filesDir, "mini_apps/$appId").canonicalFile
        require(root.parentFile == appRoot) { "Bundle does not belong to app" }
    }

    fun allows(url: String): Boolean {
        if (url == "about:blank") return true
        return try {
            val path = localFile(url).path
            path == root.path || path.startsWith(root.path + File.separator)
        } catch (_: Exception) { false }
    }

    fun resolve(route: String, bundleUri: String): String {
        val target = if (route == "/" || route.isEmpty()) bundleUri
            else root.toURI().toASCIIString().trimEnd('/') + "/" + route.trimStart('/')
        require(allows(target)) { "Route outside bundle" }
        return target
    }

    companion object {
        private fun localFile(url: String): File {
            val uri = URI(url)
            require(uri.scheme == "file" && uri.rawAuthority.isNullOrEmpty())
            return File(URI("file", null, requireNotNull(uri.path), null, null)).canonicalFile
        }
    }
}

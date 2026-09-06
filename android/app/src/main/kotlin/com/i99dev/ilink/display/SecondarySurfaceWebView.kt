package com.i99dev.ilink.display

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.webkit.GeolocationPermissions
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.ByteArrayInputStream

/** Shared offline sandbox for every overlay, Presentation and cluster surface.
 * There is deliberately no host JavaScript bridge on these visual surfaces.
 */
internal object SecondarySurfaceWebView {
    @SuppressLint("SetJavaScriptEnabled")
    fun build(ctx: Context, appId: String, bundleUri: String, route: String, tag: String): WebView {
        val policy = SecondarySurfacePolicy(bundleUri)
        policy.requireOwner(ctx.filesDir, appId)
        val target = policy.resolve(route, bundleUri)
        return WebView(ctx).apply {
            this.tag = policy
            setBackgroundColor(Color.BLACK)
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                allowFileAccess = true
                allowContentAccess = false
                allowFileAccessFromFileURLs = true
                allowUniversalAccessFromFileURLs = false
                blockNetworkLoads = true
                blockNetworkImage = true
                setGeolocationEnabled(false)
                mediaPlaybackRequiresUserGesture = true
                builtInZoomControls = false
                displayZoomControls = false
            }
            webChromeClient = object : WebChromeClient() {
                override fun onPermissionRequest(request: PermissionRequest) = request.deny()
                override fun onGeolocationPermissionsShowPrompt(
                    origin: String, callback: GeolocationPermissions.Callback,
                ) = callback.invoke(origin, false, false)
            }
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) =
                    !policy.allows(request.url.toString())
                @Deprecated("Legacy WebView navigation callback")
                override fun shouldOverrideUrlLoading(view: WebView, url: String) = !policy.allows(url)
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                    if (policy.allows(request.url.toString())) null else denied()
                @Deprecated("Legacy WebView request callback")
                override fun shouldInterceptRequest(view: WebView, url: String): WebResourceResponse? =
                    if (policy.allows(url)) null else denied()
            }
            loadUrl(target)
        }
    }

    fun navigate(view: WebView, url: String) {
        val policy = view.tag as? SecondarySurfacePolicy ?: return
        if (policy.allows(url)) view.loadUrl(url)
    }

    internal fun resolveRouteUri(bundleUri: String, route: String): String =
        SecondarySurfacePolicy(bundleUri).resolve(route, bundleUri)

    private fun denied() = WebResourceResponse(
        "text/plain", "UTF-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(ByteArray(0)),
    )
}

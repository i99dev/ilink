package com.i99dev.ilink.tv

import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `ilink/tv_ivi` — launches the native full-screen IVI player
 * ([TvIviPlayerActivity]) on the main display. Flutter owns the channel
 * browser; tapping a channel calls `play(...)` with the browsable list +
 * start index + quality cap, and the native Activity takes over rendering
 * (the only path that renders on this ROM).
 */
class TvIviPlugin(
    private val applicationContext: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "ilink/tv_ivi").also {
        it.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "play" -> {
                val urls = call.argument<List<String>>("urls").orEmpty()
                if (urls.isEmpty()) {
                    result.error("bad_args", "urls required", null)
                    return
                }
                if (urls.any { !StreamingPolicy.canPlay(applicationContext, it) }) {
                    result.error("streaming_disabled", "Enable streaming in Optional Services", null)
                    return
                }
                val intent = Intent(applicationContext, TvIviPlayerActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    putExtra(TvIviPlayerActivity.EXTRA_URLS, urls.toTypedArray())
                    putExtra(
                        TvIviPlayerActivity.EXTRA_NAMES,
                        call.argument<List<String>>("names").orEmpty().toTypedArray(),
                    )
                    putExtra(
                        TvIviPlayerActivity.EXTRA_REFERERS,
                        call.argument<List<String>>("referers").orEmpty().toTypedArray(),
                    )
                    putExtra(
                        TvIviPlayerActivity.EXTRA_USER_AGENTS,
                        call.argument<List<String>>("userAgents").orEmpty().toTypedArray(),
                    )
                    putExtra(
                        TvIviPlayerActivity.EXTRA_START_INDEX,
                        call.argument<Int>("startIndex") ?: 0,
                    )
                    putExtra(
                        TvIviPlayerActivity.EXTRA_MAX_BITRATE,
                        call.argument<Int>("maxBitrate") ?: 0,
                    )
                }
                applicationContext.startActivity(intent)
                result.success(null)
            }
            "stop" -> {
                stopPlayers(call.argument<Boolean>("networkOnly") == true)
                result.success(null)
            }
            "setStreamingEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") == true
                try {
                    StreamingPolicy.setEnabled(applicationContext, enabled)
                    if (!enabled) stopPlayers(networkOnly = true)
                } catch (failure: Exception) {
                    result.error("streaming_policy", failure.message, null)
                    return
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun stopPlayers(networkOnly: Boolean = false) {
        applicationContext.sendBroadcast(
            Intent(TvIviPlayerActivity.ACTION_STOP).setPackage(applicationContext.packageName)
                .putExtra("networkOnly", networkOnly),
        )
        PassengerLauncher.stop(applicationContext, networkOnly)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}

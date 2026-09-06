package com.i99dev.ilink.tv

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.ViewGroup
import android.view.WindowManager
import androidx.core.content.ContextCompat
import androidx.media3.common.AudioAttributes
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.ui.PlayerView

/**
 * Full-screen live-TV player for the **passenger display**.
 *
 * Why a standalone Activity (and not the in-app Flutter `video_player`):
 * on this BYD / MT6983 unit a *single process* cannot keep one decoder on
 * the IVI (`video_player`) and attach a second decoder to the FLAG_SECURE
 * passenger display (display 2) — the IVI surface wedges to black until a
 * full process restart (proven via an in-process `Presentation`). A
 * **separate process** sidesteps it: the SoC happily runs two AVC
 * decoders across two PIDs (verified on-car 2026-05-21 — a second app
 * decoding on display 2 left the IVI rendering live video). Hence this
 * Activity declares `android:process=":tvpassenger"` in the manifest.
 *
 * Launch (from [TvPassengerPlugin], over loopback ADB — the only path a
 * non-system app can pin a launch to a non-default display; in-process
 * `setLaunchDisplayId` needs INTERNAL_SYSTEM_WINDOW which we lack):
 *
 *     am start-activity --display 2 \
 *         -n com.i99dev.ilink/.tv.PassengerPlayerActivity \
 *         --es url 'https://.../playlist.m3u8' \
 *         --es title 'MBC 1'
 *
 * Re-cast (channel switch while already up) reuses the singleInstance
 * instance via [onNewIntent] — no decoder teardown/relaunch churn. Stop
 * is a same-app cross-process broadcast ([ACTION_STOP]); we deliberately
 * cannot `am force-stop` because that kills the whole package (incl. the
 * IVI host). Mirrors [com.i99dev.ilink.display.ClusterActivity]'s
 * exported-for-shell, own-task-affinity shape.
 */
@UnstableApi
class PassengerPlayerActivity : Activity() {

    companion object {
        private const val TAG = "PassengerPlayer"

        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"
        const val EXTRA_REFERER = "referer"
        const val EXTRA_USER_AGENT = "userAgent"

        /** Int extra: max video variant bandwidth (bits/sec) the
         *  DefaultTrackSelector caps to; absent / 0 = no cap. */
        const val EXTRA_MAX_BITRATE = "maxBitrate"

        /** Action filter for the am-start launch (manual `adb shell`
         *  testing convenience; the plugin uses the explicit `-n`
         *  component form). */
        const val ACTION_OPEN = "com.i99dev.ilink.action.OPEN_TV_PASSENGER"

        /** Same-app broadcast that finishes the player from the IVI
         *  process. Sent with `setPackage(packageName)` so it stays
         *  in-app; the receiver is registered NOT_EXPORTED. */
        const val ACTION_STOP = "com.i99dev.ilink.action.TV_PASSENGER_STOP"
    }

    private var player: ExoPlayer? = null
    private var playerView: PlayerView? = null
    private var trackSelector: DefaultTrackSelector? = null

    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val playingUrl = player?.currentMediaItem?.localConfiguration?.uri?.toString().orEmpty()
            if (intent?.getBooleanExtra("networkOnly", false) == true && StreamingPolicy.isLocalMedia(playingUrl)) return
            player?.stop()
            Log.i(TAG, "stop broadcast received — finishing")
            finish()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Keep the panel awake + paint edge-to-edge. The passenger panel
        // is FLAG_SECURE already; we don't add FLAG_SECURE to our window
        // (our content isn't DRM-protected and a secure window can't be
        // screenshotted for support diagnostics).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_FULLSCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
        )

        val view = PlayerView(this).apply {
            useController = false
            setBackgroundColor(Color.BLACK)
            setShutterBackgroundColor(Color.BLACK)
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        setContentView(view)
        playerView = view

        ContextCompat.registerReceiver(
            this,
            stopReceiver,
            IntentFilter(ACTION_STOP),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )

        startPlayback(intent)
    }

    /** Re-cast: a new channel was sent while the player is already up.
     *  singleInstance delivers it here instead of spawning a second
     *  instance, so we just swap the media item — no decoder churn. */
    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        startPlayback(intent)
    }

    private fun startPlayback(intent: Intent?) {
        val url = intent?.getStringExtra(EXTRA_URL)
        if (url.isNullOrBlank()) {
            Log.e(TAG, "missing url extra — finishing")
            finish()
            return
        }
        if (!StreamingPolicy.canPlay(this, url)) {
            player?.stop()
            finish()
            return
        }
        val title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
        val referer = intent.getStringExtra(EXTRA_REFERER)
        val userAgent = intent.getStringExtra(EXTRA_USER_AGENT)
        val maxBitrate = intent.getIntExtra(EXTRA_MAX_BITRATE, 0)
        Log.i(TAG, "play '$title' on display=${displayId()} bitrate=$maxBitrate url=$url")

        val httpFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
        if (!userAgent.isNullOrBlank()) httpFactory.setUserAgent(userAgent)
        if (!referer.isNullOrBlank()) {
            httpFactory.setDefaultRequestProperties(mapOf("Referer" to referer))
        }

        // One track selector, reused across re-casts so a quality change
        // applies to the live player without a rebuild.
        val selector = trackSelector ?: DefaultTrackSelector(this).also {
            trackSelector = it
        }
        selector.setParameters(
            selector.buildUponParameters()
                .setMaxVideoBitrate(if (maxBitrate > 0) maxBitrate else Int.MAX_VALUE)
                .build(),
        )

        // Reuse the existing player on re-cast; build it once otherwise.
        val p = player ?: ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(
                DefaultDataSource.Factory(this, StreamingPolicy.guardedHttp(this, httpFactory)),
            ))
            .setTrackSelector(selector)
            .build()
            .also { built ->
                // Request audio focus so in-app radio / other media ducks
                // while the passenger watches TV.
                built.setAudioAttributes(AudioAttributes.DEFAULT, true)
                built.addListener(object : Player.Listener {
                    override fun onPlayerError(error: PlaybackException) {
                        Log.w(TAG, "playback error: ${error.errorCodeName}", error)
                    }
                })
                player = built
                playerView?.player = built
            }

        p.setMediaItem(MediaItem.fromUri(url))
        p.prepare()
        p.playWhenReady = true
    }

    private fun displayId(): Int = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display?.displayId ?: -1
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay.displayId
        }
    } catch (_: Throwable) {
        -1
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(stopReceiver)
        } catch (_: Throwable) {
            // Receiver may already be gone if onCreate bailed early.
        }
        player?.release()
        player = null
        playerView?.player = null
        playerView = null
        super.onDestroy()
    }
}

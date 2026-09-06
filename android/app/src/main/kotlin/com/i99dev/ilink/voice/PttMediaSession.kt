package com.i99dev.ilink.voice

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.util.Log
import android.view.KeyEvent

/**
 * Dedicated MediaSession that captures steering-wheel media buttons
 * (MEDIA_PREVIOUS/NEXT/PLAY_PAUSE/HEADSETHOOK) and forwards them to
 * [VoiceChannel.pushHardwareKey] so Dart can toggle the mic.
 *
 * Why a MediaSession instead of Activity.onKeyDown alone:
 *   - onKeyDown only fires when the Activity has input focus.
 *   - Android routes ACTION_MEDIA_BUTTON intents to the most recently
 *     active MediaSession system-wide, so a MediaSession keeps working
 *     when the app is backgrounded, the user has switched to another
 *     app, or the Activity is paused. This is the standard pattern
 *     used by Google Assistant, Spotify's Car Mode, etc.
 *
 * We keep this session "primary" by re-activating it and publishing a
 * fresh PlaybackState whenever the user interacts with voice (or on
 * create), so it wins routing over any other MediaSession in the same
 * process (e.g. just_audio_background for TTS playback).
 *
 * On BYD head units specifically, steering-wheel buttons emit
 * MEDIA_PREVIOUS (88) and MEDIA_NEXT (87) — see the keycode list in
 * MainActivity.onKeyDown for the catalogue.
 */
class PttMediaSession(
    private val context: Context,
    private val voiceChannel: VoiceChannel,
) {
    private var session: MediaSessionCompat? = null

    fun start() {
        if (session != null) return
        val s = MediaSessionCompat(context, TAG).apply {
            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS,
            )
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                    val key: KeyEvent? =
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            mediaButtonIntent.getParcelableExtra(
                                Intent.EXTRA_KEY_EVENT,
                                KeyEvent::class.java,
                            )
                        } else {
                            @Suppress("DEPRECATION")
                            mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
                        }
                    // Only the initial ACTION_DOWN of MEDIA_PREVIOUS ("«")
                    // toggles the mic. Repeats + other keycodes fall through
                    // to the system so music controls still work.
                    if (key == null ||
                        key.action != KeyEvent.ACTION_DOWN ||
                        key.repeatCount > 0 ||
                        key.keyCode != KeyEvent.KEYCODE_MEDIA_PREVIOUS) {
                        return super.onMediaButtonEvent(mediaButtonIntent)
                    }
                    voiceChannel.pushHardwareKey()
                    refreshState() // stay primary for the next press
                    return true
                }

                // Modern transport-control callback: the framework decoded
                // the button and routed it as "skip to previous." Same
                // physical key, so forward to the mic toggle.
                override fun onSkipToPrevious() {
                    voiceChannel.pushHardwareKey()
                    refreshState()
                }
            })
        }
        session = s
        refreshState()
        s.isActive = true
    }

    /**
     * Republish a PlaybackState so this session becomes/stays the
     * primary media-button target. Called on activation and after every
     * handled press.
     */
    private fun refreshState() {
        val s = session ?: return
        val state = PlaybackStateCompat.Builder()
            .setActions(
                PlaybackStateCompat.ACTION_PLAY or
                    PlaybackStateCompat.ACTION_PAUSE or
                    PlaybackStateCompat.ACTION_PLAY_PAUSE or
                    PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                    PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS,
            )
            .setState(PlaybackStateCompat.STATE_PLAYING, 0, 1.0f, SystemClock.elapsedRealtime())
            .build()
        s.setPlaybackState(state)
    }

    fun stop() {
        session?.release()
        session = null
    }

    companion object {
        private const val TAG = "PttMediaSession"
    }
}

package com.i99dev.ilink.voice

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.i99dev.ilink.MainActivity
import com.i99dev.ilink.R
import io.flutter.plugin.common.EventChannel

/**
 * Foreground service that keeps the Flutter engine + WebRTC peer connection
 * alive while the user is in another app. The service owns:
 *
 *   - the foreground notification (so Android doesn't kill the process)
 *   - the audio focus request (so a Spotify ducking is reversible)
 *
 * It does NOT own the WebRTC peer connection — that stays in Dart, created
 * by RealtimeClient. Moving the peer to Kotlin would require a second
 * implementation and serializing tool calls across the channel. Instead
 * the service's job is purely to keep the hosting process resident.
 *
 * Lifecycle: VoiceController.start() calls VoiceChannel.startService; stop
 * calls stopService. Transient focus loss (an app takes focus briefly) is
 * surfaced as an event; VoiceController decides whether to pause or drop.
 */
class VoiceSessionService : Service() {

    companion object {
        private const val TAG = "VoiceSessionService"
        private const val CHANNEL_ID = "dash.voice.session"
        private const val NOTIFICATION_ID = 4242

        private const val ACTION_START = "com.i99dev.ilink.voice.START"
        private const val ACTION_STOP = "com.i99dev.ilink.voice.STOP"
        private const val ACTION_UPDATE_TEXT = "com.i99dev.ilink.voice.UPDATE_TEXT"
        private const val EXTRA_TEXT = "text"

        // Bound by VoiceChannel so the service can push audio-focus events
        // to Dart. Volatile because the service thread and main thread
        // both touch it. Null before Dart starts listening.
        @Volatile
        private var eventSink: EventChannel.EventSink? = null

        fun bindEventSink(sink: EventChannel.EventSink?) {
            eventSink = sink
        }

        /**
         * Fire a hardware-key (wheel voice button) event to Dart from a
         * process component that has no [VoiceChannel] instance — the
         * accessibility key filter and the wheel-voice resolver. Returns
         * true only when a listener sink was bound and accepted it; a false
         * return tells [WheelVoiceController] the Flutter engine isn't
         * listening so it should bring the app up via an assist intent.
         *
         * Must be called on the platform main thread (EventSink.success
         * requires it); [WheelVoiceController.fireVoice] guarantees that.
         */
        fun pushHardwareKey(): Boolean {
            val sink = eventSink ?: return false
            return try {
                sink.success(mapOf("type" to VoiceChannel.EVENT_HARDWARE_KEY))
                true
            } catch (_: Throwable) {
                // Sink stale (engine torn down between the null-check and
                // the dispatch) — treat as "not listening".
                false
            }
        }

        fun start(context: Context) {
            val intent = Intent(context, VoiceSessionService::class.java)
                .setAction(ACTION_START)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, VoiceSessionService::class.java)
                .setAction(ACTION_STOP)
            context.startService(intent)
        }

        fun updateNotificationText(context: Context, text: String) {
            val intent = Intent(context, VoiceSessionService::class.java)
                .setAction(ACTION_UPDATE_TEXT)
                .putExtra(EXTRA_TEXT, text)
            context.startService(intent)
        }

        private fun dispatchEvent(type: String) {
            try {
                eventSink?.success(mapOf("type" to type))
            } catch (_: Throwable) { /* sink stale; drop */ }
        }
    }

    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private var currentText: String = "Voice assistant active"

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS ->
                dispatchEvent(VoiceChannel.EVENT_AUDIO_FOCUS_LOSS)
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK ->
                dispatchEvent(VoiceChannel.EVENT_AUDIO_FOCUS_LOSS_TRANSIENT)
            AudioManager.AUDIOFOCUS_GAIN ->
                dispatchEvent(VoiceChannel.EVENT_AUDIO_FOCUS_GAIN)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> enterForeground()
            ACTION_STOP -> exitForeground()
            ACTION_UPDATE_TEXT -> {
                intent.getStringExtra(EXTRA_TEXT)?.let {
                    currentText = it
                    refreshNotification()
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // If the user swipes the task away, tear down cleanly so Dart
        // learns the session is gone and can reset UI.
        dispatchEvent(VoiceChannel.EVENT_SERVICE_KILLED)
        exitForeground()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        // Defensive: a kill that bypasses exitForeground must still clear
        // the bubble pulse.
        VoiceActivityState.setActive(false)
        abandonAudioFocus()
        super.onDestroy()
    }

    private fun enterForeground() {
        ensureChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        requestAudioFocus()
        // A session is now live — let the floating bubble pulse while the
        // assistant is listening/working (it observes this).
        VoiceActivityState.setActive(true)
    }

    private fun exitForeground() {
        VoiceActivityState.setActive(false)
        abandonAudioFocus()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun refreshNotification() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun buildNotification(): Notification {
        val tapIntent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pending = PendingIntent.getActivity(
            this,
            0,
            tapIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Dash voice")
            .setContentText(currentText)
            .setContentIntent(pending)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setShowWhen(false)
            .build()
    }

    private fun ensureChannel() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Voice assistant",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while the Dash voice assistant is active"
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun requestAudioFocus() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager = am
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANT)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val request = AudioFocusRequest.Builder(
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
        )
            .setAudioAttributes(attrs)
            .setOnAudioFocusChangeListener(focusListener)
            .setAcceptsDelayedFocusGain(true)
            .build()
        focusRequest = request
        val r = am.requestAudioFocus(request)
        Log.d(TAG, "audio focus request result=$r")
    }

    private fun abandonAudioFocus() {
        val req = focusRequest ?: return
        audioManager?.abandonAudioFocusRequest(req)
        focusRequest = null
    }
}

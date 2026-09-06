package com.i99dev.ilink.voice.ondevice

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Dart-facing seam for the on-device Vosk recognizer (Phase 1b). Mirrors
 * the Dart `OnDeviceRecognizer` interface (see
 * `lib/features/voice/ondevice/on_device_recognizer.dart`):
 *
 *   method  ilink/ondevice_voice
 *     modelPresent           -> Bool         is a Kaldi model provisioned?
 *     applyGrammar {grammar} -> {ok,error?}  load model + constrain to grammar
 *     start                  -> {ok}         begin continuous recognition
 *     stop / dispose         -> {ok}
 *   event   ilink/ondevice_voice/events    {text:String, isFinal:Bool}
 *
 * The model PATH is resolved natively ([VoskModelStore]) — Dart only ever
 * sends the grammar JSON (from `VoiceGrammar.toVoskGrammarJson`), so the
 * provisioning/CDN concern stays entirely on the native side.
 *
 * Model load + recognition run on a worker thread (native I/O + the
 * always-on mic loop must never touch the platform thread); results are
 * marshalled back to the main thread before hitting the EventSink.
 */
class OnDeviceVoiceChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        const val METHOD = "ilink/ondevice_voice"
        const val EVENTS = "ilink/ondevice_voice/events"
        const val PROVISION_EVENTS = "ilink/ondevice_voice/provision"
        // Raw 16-bit LE PCM of an utterance Vosk rejected ([unk]) — Dart runs
        // the Moonshine fallback over it. Only emitted when fallback is on.
        const val UTTERANCE_EVENTS = "ilink/ondevice_voice/utterance"
        private const val TAG = "OnDeviceVoice"
    }

    private val method = MethodChannel(messenger, METHOD)
    private val events = EventChannel(messenger, EVENTS)
    private val provisionEvents = EventChannel(messenger, PROVISION_EVENTS)
    private val utteranceEvents = EventChannel(messenger, UTTERANCE_EVENTS)
    private val recognizer = VoskGrammarRecognizer()
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var sink: EventChannel.EventSink? = null

    @Volatile
    private var provisionSink: EventChannel.EventSink? = null

    @Volatile
    private var utteranceSink: EventChannel.EventSink? = null

    fun register() {
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
                sink = eventSink
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
        provisionEvents.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
                provisionSink = eventSink
            }

            override fun onCancel(arguments: Any?) {
                provisionSink = null
            }
        })
        utteranceEvents.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
                utteranceSink = eventSink
            }

            override fun onCancel(arguments: Any?) {
                utteranceSink = null
            }
        })
        method.setMethodCallHandler { call, result ->
            when (call.method) {
                "modelPresent" -> {
                    val version = call.argument<String>("version") ?: ""
                    result.success(VoskModelStore.isPresent(context, version))
                }

                "fallbackModelPresent" -> {
                    val version = call.argument<String>("version") ?: ""
                    result.success(MoonshineModelStore.isPresent(context, version))
                }

                "fallbackModelPath" -> {
                    val version = call.argument<String>("version") ?: ""
                    result.success(MoonshineModelStore.modelPathOrNull(context, version))
                }

                "deleteFallback" -> {
                    val version = call.argument<String>("version") ?: ""
                    result.success(
                        mapOf("ok" to VoskModelStore.deleteModel(context, version)),
                    )
                }

                "setFallbackEnabled" -> {
                    recognizer.setFallbackEnabled(call.argument<Boolean>("enabled") ?: false)
                    result.success(mapOf("ok" to true))
                }

                "setModelDownloadsEnabled" -> {
                    VoskModelProvisioner.setDownloadsEnabled(call.argument<Boolean>("enabled") ?: false)
                    result.success(true)
                }

                "provisionModel" -> {
                    val allowNetwork = call.argument<Boolean>("allowNetwork") ?: false
                    val url = call.argument<String>("url")
                    val version = call.argument<String>("version") ?: "1"
                    if (url.isNullOrEmpty()) {
                        result.success(mapOf("ok" to false, "error" to "no_url"))
                    } else {
                        worker.execute {
                            // Emit byte-progress to the provision EventChannel,
                            // throttled to whole-percent changes so we don't
                            // flood the platform channel.
                            var lastPct = -1
                            val ok = VoskModelProvisioner.provision(
                                context,
                                url,
                                version,
                                allowNetwork = allowNetwork,
                                onProgress = { received, total ->
                                    val pct = if (total > 0) {
                                        ((received * 100) / total).toInt()
                                    } else {
                                        -1
                                    }
                                    if (pct != lastPct) {
                                        lastPct = pct
                                        main.post {
                                            provisionSink?.success(
                                                mapOf("received" to received, "total" to total),
                                            )
                                        }
                                    }
                                },
                            )
                            main.post { result.success(mapOf("ok" to ok)) }
                        }
                    }
                }

                "provisionFallback" -> {
                    val allowNetwork = call.argument<Boolean>("allowNetwork") ?: false
                    val url = call.argument<String>("url")
                    val version = call.argument<String>("version") ?: "1"
                    if (url.isNullOrEmpty()) {
                        result.success(mapOf("ok" to false, "error" to "no_url"))
                    } else {
                        worker.execute {
                            var lastPct = -1
                            val ok = VoskModelProvisioner.provision(
                                context,
                                url,
                                version,
                                allowNetwork = allowNetwork,
                                onProgress = { received, total ->
                                    val pct = if (total > 0) {
                                        ((received * 100) / total).toInt()
                                    } else {
                                        -1
                                    }
                                    if (pct != lastPct) {
                                        lastPct = pct
                                        main.post {
                                            provisionSink?.success(
                                                mapOf("received" to received, "total" to total),
                                            )
                                        }
                                    }
                                },
                                // ONNX bundle, not a Kaldi tree — different check.
                                isPresent = MoonshineModelStore::isPresent,
                            )
                            main.post { result.success(mapOf("ok" to ok)) }
                        }
                    }
                }

                "applyGrammar" -> {
                    val grammar = call.argument<String>("grammar") ?: "[]"
                    val version = call.argument<String>("version") ?: ""
                    worker.execute {
                        val path = VoskModelStore.modelPathOrNull(context, version)
                        if (path == null) {
                            main.post {
                                result.success(
                                    mapOf("ok" to false, "error" to "model_not_provisioned"),
                                )
                            }
                            return@execute
                        }
                        try {
                            recognizer.load(path, grammar)
                            main.post { result.success(mapOf("ok" to true)) }
                        } catch (t: Throwable) {
                            Log.e(TAG, "applyGrammar failed: ${t.message}", t)
                            main.post {
                                result.success(
                                    mapOf("ok" to false, "error" to (t.message ?: "load_failed")),
                                )
                            }
                        }
                    }
                }

                "start" -> {
                    worker.execute {
                        recognizer.start(
                            onText = { text, isFinal ->
                                main.post {
                                    sink?.success(mapOf("text" to text, "isFinal" to isFinal))
                                }
                            },
                            onUtteranceMiss = { pcm ->
                                // Raw 16-bit LE PCM → Dart Moonshine fallback.
                                main.post { utteranceSink?.success(pcm) }
                            },
                            onError = { err ->
                                main.post { sink?.error("ondevice_voice", err, null) }
                            },
                        )
                    }
                    result.success(mapOf("ok" to true))
                }

                "stop" -> {
                    worker.execute { recognizer.stop() }
                    result.success(mapOf("ok" to true))
                }

                "dispose" -> {
                    worker.execute { recognizer.close() }
                    result.success(mapOf("ok" to true))
                }

                else -> result.notImplemented()
            }
        }
    }
}

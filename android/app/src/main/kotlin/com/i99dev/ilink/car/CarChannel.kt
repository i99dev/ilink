package com.i99dev.ilink.car

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * MethodChannel surface exposed to Flutter. Routes to:
 *   - [AutoFeatureService] → [UnitDispatcher] → testing_case unit DEX files
 *   - [AcFeatureService] → byd_airconditioning direct binder (fragrance)
 *   - [CarStatusProviderSource] → BYD ContentProvider reads + observers
 *     (Phase-9; backs the mini-app SDK's family-snapshot families that
 *     don't have a live-state binder source).
 *
 * Handlers run on a background task queue so shell I/O doesn't trip
 * NetworkOnMainThreadException.
 */
class CarChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        const val CHANNEL = "ilink/car"
        const val OBSERVER_EVENT_CHANNEL = "ilink/car/observers"
        /// AutoCarRegistry value-change deltas — every push frame the
        /// registry's subscriptions receive forwards onto this channel
        /// as `{name: <catalogName>, value: <int>}`. SDK consumers
        /// (CarFeatureApi.watch / featureValueProvider) attach here
        /// instead of polling.
        const val REGISTRY_EVENT_CHANNEL = "ilink/car/registry"
        const val TAG = "CarChannel"
    }

    private val channel = MethodChannel(
        messenger,
        CHANNEL,
        StandardMethodCodec.INSTANCE,
        messenger.makeBackgroundTaskQueue(),
    )
    /// Phase-9: streaming channel for ContentObserver pushes. The
    /// EventChannel is multiplexed — every emitted message carries
    /// `{family, observerId, snapshot}` so the Dart side can fan
    /// out to multiple subscribers from a single broadcast stream.
    private val observerEventChannel = EventChannel(messenger, OBSERVER_EVENT_CHANNEL)

    /// Registry delta channel — wired in `register()`. The
    /// AutoFeatureService.registry.onChange callback forwards
    /// (name, value) tuples here on every push frame.
    private val registryEventChannel = EventChannel(messenger, REGISTRY_EVENT_CHANNEL)
    @Volatile private var registrySink: EventChannel.EventSink? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    // Eager — InAppPushManager must register its BydPushDevice subclasses
    // BEFORE the framework starts dispatching push for our process,
    // otherwise we miss every event between app-start and the first
    // method-channel call. Lazy init also masks construct-time crashes
    // until Dart triggers the surface, which is hostile to debugging.
    private val auto = AutoFeatureService(context)
    private val ac by lazy { AcFeatureService(context) }
    /// The CarStatusProviderSource needs a [CarTableSource] to look up
    /// each family's URI. We reuse whatever [auto] (UnitDispatcher) has
    /// already loaded — that's the single source of truth, and lets the
    /// encrypted-asset rotation in [EncryptedCarTableSource] take effect
    /// without re-reading the asset twice.
    private val statusProvider by lazy {
        CarStatusProviderSource(context, auto.tableSource())
    }

    /// Per-process incrementing observer id. Returned to Dart on
    /// `observeContentProvider` and required back on
    /// `unobserveContentProvider` so two subscribers to the same family
    /// can unsubscribe independently.
    private val nextObserverId = AtomicLong(1)
    /// Active EventChannel sinks keyed by `family:observerId`. The
    /// EventChannel publishes a single broadcast stream; we filter
    /// per-key on the Dart side.
    private val activeSinks = ConcurrentHashMap<String, EventChannel.EventSink>()
    /// One persistent sink for the EventChannel; messages are routed
    /// per-key via the `family + observerId` envelope. Set in
    /// [register] and unset on stream close.
    @Volatile private var streamSink: EventChannel.EventSink? = null

    fun register() {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "runAction" -> {
                        val id = call.argument<String>("id") ?: ""
                        val args = call.argument<Map<String, Any?>>("args") ?: emptyMap()
                        result.success(auto.runAction(id, args))
                    }
                    "runUnit" -> {
                        val unit = call.argument<String>("unit") ?: ""
                        @Suppress("UNCHECKED_CAST")
                        val args = call.argument<List<String>>("args") ?: emptyList()
                        result.success(auto.runUnit(unit, args))
                    }
                    "knownActions" -> result.success(auto.knownActions())
                    "knownUnits" -> result.success(auto.knownUnits())
                    // Auto-discovered registry — every catalog feature
                    // currently live on this car. Returns a flat
                    // name → int map. The UI groups by namespace
                    // prefix client-side; no per-trim wiring.
                    "allFeaturesAuto" -> result.success(auto.allFeaturesAuto())
                    "allKnownFeatures" -> result.success(auto.allKnownFeatures())
                    // label → catalog-name bridge for legacy consumers
                    // (CarGateAdapter rebuilds the gate from the
                    // store using this mapping). Pulled once at SDK
                    // construct on the Dart side.
                    "labelToCatalog" -> result.success(auto.labelToCatalog())
                    "registryStats" -> result.success(auto.registryStats())
                    "watchdogStats" -> result.success(auto.watchdogStats())
                    // SDK fallback — when a per-feature watch sees
                    // no cached value (registry's brute-force probe
                    // missed the name, OR push hasn't fired yet for
                    // a state-change-only signal), the SDK calls
                    // this for a fresh per-feature read via daemon
                    // getInt + framework catalog resolve.
                    "getValueByName" -> {
                        val name = call.argument<String>("name") ?: ""
                        result.success(auto.getValueByName(name))
                    }
                    // Bulk variant — SDK coalesces N pending watches
                    // into one round-trip via the Phase 3 grouped
                    // getIntArray path. Single 35ms call vs N × 5ms.
                    "getValuesByName" -> {
                        @Suppress("UNCHECKED_CAST")
                        val names = call.argument<List<String>>("names") ?: emptyList()
                        result.success(auto.getValuesByName(names))
                    }
                    // Registry-free push subscription. SDK calls this
                    // for the boot warm set + on first watch() of any
                    // additional name. Returns the subset that
                    // successfully subscribed.
                    "subscribePushByNames" -> {
                        @Suppress("UNCHECKED_CAST")
                        val names = call.argument<List<String>>("names") ?: emptyList()
                        result.success(auto.subscribePushByNames(names))
                    }
                    "daemonStatus" -> result.success(mapOf(
                        "adb" to com.i99dev.ilink.adb.AdbShellBridge.isConnected(),
                        "daemon" to com.i99dev.ilink.adb.AdbShellBridge.isDaemonReady(),
                    ))
                    "carIdentity" -> result.success(CarIdentity.snapshot(context))
                    "carIdentityLocalOnly" -> result.success(CarIdentity.localOnly())
                    "acTransact" -> result.success(
                        ac.transact(
                            call.argument<String>("service") ?: "",
                            call.argument<String>("method") ?: "",
                            call.argument<Map<String, Any?>>("args") ?: emptyMap(),
                        )
                    )
                    // Phase-9: ContentProvider family reads + observers.
                    "readContentProvider" -> {
                        val family = call.argument<String>("family") ?: ""
                        result.success(statusProvider.readFamily(family))
                    }
                    "observeContentProvider" -> {
                        val family = call.argument<String>("family") ?: ""
                        val observerId = "obs-${nextObserverId.getAndIncrement()}"
                        val obs = tableSourceForObserver(family)
                        val descend = obs?.notifyForDescendants ?: true
                        val throttle = obs?.throttleMs ?: 200
                        val started = statusProvider.observeFamily(
                            family = family,
                            observerId = observerId,
                            notifyForDescendants = descend,
                            throttleMs = throttle,
                        ) { snapshot ->
                            // Synthesise an envelope so the Dart side can
                            // demultiplex by (family, observerId).
                            streamSink?.success(
                                mapOf(
                                    "family" to family,
                                    "observerId" to observerId,
                                    "snapshot" to snapshot,
                                )
                            )
                        }
                        result.success(if (started == null) null else mapOf(
                            "family" to family,
                            "observerId" to observerId,
                        ))
                    }
                    "unobserveContentProvider" -> {
                        val family = call.argument<String>("family") ?: ""
                        val observerId = call.argument<String>("observerId") ?: ""
                        statusProvider.unobserveFamily(family, observerId)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.e(TAG, "channel error in ${call.method}: ${e.message}", e)
                result.error(
                    e.javaClass.simpleName,
                    e.message,
                    e.stackTraceToString(),
                )
            }
        }
        observerEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                streamSink = events
            }

            override fun onCancel(arguments: Any?) {
                streamSink = null
            }
        })
        // Registry delta channel — wires AutoCarRegistry's onChange
        // callback into the EventChannel. SDK consumers
        // (CarFeatureApi.watch / featureValueProvider) attach here
        // and receive `(name, value)` envelopes for every push frame
        // — no more 1-second polling on the Dart side.
        registryEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                registrySink = events
                val emit: (String, Int) -> Unit = { name, value ->
                    // EventSink.success must run on the main thread.
                    // Push frames arrive on the framework's dispatcher
                    // thread (varies by ROM), so always hop.
                    mainHandler.post {
                        registrySink?.success(mapOf("name" to name, "value" to value))
                    }
                }
                auto.registry.onChange = emit
                // Multiplex SDK-direct subscriptions (registry-free
                // path used by BydClient.watch + boot warmup) into the
                // same sink so consumers can listen on a single event
                // channel and not care which path produced the push.
                auto.sdkPushOnChange = emit
            }

            override fun onCancel(arguments: Any?) {
                auto.registry.onChange = null
                auto.sdkPushOnChange = null
                registrySink = null
            }
        })
    }

    /// Tear-down hook for [MainActivity] / Application onDestroy. Drops
    /// every observer + the EventChannel sink so a hot-restart-style
    /// reload doesn't leak ContentObserver registrations.
    fun dispose() {
        statusProvider.shutdown()
        streamSink = null
    }

    private fun tableSourceForObserver(family: String): ObserverChannelEntry? =
        auto.tableSource().observerChannelFor(family)
}

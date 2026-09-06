import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// Plain-data position — detached from the geolocator `Position` class so
/// tests and alt sources (mocked GPS, hand-entered coords) don't pull in
/// the platform plugin.
@immutable
class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    this.accuracyM,
    this.headingDeg,
    this.speedMps,
    this.at,
  });

  final double latitude;
  final double longitude;
  final double? accuracyM;

  /// Course over ground in degrees (0 = north), or null when unknown
  /// (stationary fixes often carry no bearing). Drives the live-map
  /// heading arrow + the moving/stopped classification (server-side).
  final double? headingDeg;

  /// Ground speed in m/s, or null when unknown.
  final double? speedMps;

  final DateTime? at;
}

/// Outcome of a location-permission request. Matches the three real
/// states the OS exposes — granted, denied (transient or permanent),
/// or "platform can't say" (e.g. desktop with no permission model).
/// Adapters in feature code map this to richer per-feature enums.
enum LocationPermissionOutcome { granted, denied, unavailable }

/// Source of GPS fixes. Production impl wraps [Geolocator]; tests inject
/// a stub that returns canned values without touching platform channels.
abstract class LocationService {
  Future<LocationFix?> current();
  Stream<LocationFix> stream();

  /// Centralised "give me a usable fix, fast" helper. Prefer this over
  /// the raw [current] / [currentLocationProvider] read at any call
  /// site that opens a session, mints credentials, or takes a one-shot
  /// snapshot of where the car is — the cached-stream path can return
  /// a multi-day-old fix on a parked car (Android's
  /// FusedLocationProvider keeps the last value across reboots), which
  /// is exactly the wrong thing to ship to a backend that thinks
  /// "no GPS" means the right answer.
  ///
  /// Resolution order:
  ///   1. If the in-process stream cache has a fix newer than
  ///      [maxCacheAge] → return it (zero round-trip).
  ///   2. Else attempt a fresh [getCurrentPosition] under a hard
  ///      [timeout] — bounds the latency added to the caller's
  ///      critical path.
  ///   3. On timeout / permission-off / GPS-radio-off → return null.
  ///      Callers should treat that as "no GPS, ask the user to name
  ///      a place" rather than substituting a market default.
  ///
  /// Defaults are tuned for the voice session-mint path: 5 min cache
  /// is fresh enough that a parked car reusing a 30 s-old fix sees
  /// zero added latency, while a stale 2-day-old fix forces a
  /// re-acquire under a 1.5 s budget — past which we'd rather start
  /// the voice session without coords than block the mic open.
  Future<LocationFix?> freshFix({
    Duration maxCacheAge = const Duration(minutes: 5),
    Duration timeout = const Duration(milliseconds: 1500),
  });

  /// Resolve runtime location permission — returns `true` when the OS
  /// has granted `whileInUse` or `always` AND the location service is
  /// enabled. Centralised so non-fix consumers (mini-app WebView's
  /// `onGeolocationPermissionsShowPrompt`, mini-app bridge's bespoke
  /// read-handler) share one permission state machine instead of
  /// each running their own Geolocator dance.
  Future<bool> ensurePermission();

  /// Request the OS-level runtime location permission and return the
  /// classified outcome. Used by the onboarding flow which needs to
  /// distinguish "unable to determine" from "denied" — broader than
  /// what [ensurePermission] returns.
  Future<LocationPermissionOutcome> requestPermission();
}

/// Settings shared between one-shot and stream reads. Pulled out so
/// `LocationAccuracy.low` + the 25 m `distanceFilter` are documented
/// once instead of on every call site, AND so the Android-specific
/// `AndroidSettings` (which adds `intervalDuration`) can be selected
/// at the platform switch below.
///
/// Per `flutter-geolocator` doc id `/baseflow/flutter-geolocator`
/// ("Configure Android-Specific Location Settings"), `AndroidSettings`
/// extends `LocationSettings` with an `intervalDuration` that lets
/// FusedLocationProvider coalesce our requests with other apps' polls
/// — meaningful battery and CPU savings on the IVI head unit where
/// BYD's own apps already poll location at a high rate.
LocationSettings _buildLocationSettings({Duration? timeLimit}) {
  if (defaultTargetPlatform == TargetPlatform.android) {
    // ``forceLocationManager: true`` is critical on the BYD head
    // unit. The default path (FusedLocationProvider via Play
    // Services) is broken on this OEM — our subscription never
    // reaches the GNSS chip, so the cached fix stays days old
    // even when 57 satellites are visible. Waze, Huawei Maps,
    // AMap, and the original ``LocationBridge.kt`` (removed
    // Apr 20 2026 with the map screen) all bypass Fused and go
    // straight to ``android.location.LocationManager``; we
    // match that path. Verified at runtime: with Fused, only
    // ``com.byd.gpsinfo`` shows up in ``dumpsys location``;
    // with LocationManager our package id appears alongside it
    // and fresh fixes start emitting within 1–3 s.
    //
    // High-accuracy + short interval keepalive: head unit is
    // always plugged in, no battery concern. The shell mounts
    // ``currentLocationProvider`` always-on (see ``_KeepAlive``)
    // so this stream runs the whole time the app is in the
    // foreground.
    // ``foregroundNotificationConfig`` is critical on Android 8+
    // for continuous LocationManager subscriptions — without a
    // foreground service, the OS aggressively throttles our
    // requests so we appear in ``dumpsys location`` listeners but
    // the GNSS chip never wakes for our package. Verified
    // empirically on the BYD HU: the keepalive only starts
    // populating ``_lastStreamFix`` once the foreground notification
    // is declared. The notification itself is invisible on the head
    // unit (no visible status bar surface in cockpit mode) but its
    // presence is what un-throttles the request.
    return AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
      intervalDuration: const Duration(seconds: 5),
      forceLocationManager: true,
      timeLimit: timeLimit,
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'Location active',
        notificationText: 'ilink uses GPS for navigation + voice replies.',
        enableWakeLock: true,
        setOngoing: true,
      ),
    );
  }
  // iOS / desktop / web fall back to the cross-platform settings; the
  // platform-specific tuning only matters on Android in our deployment.
  return LocationSettings(
    accuracy: LocationAccuracy.low,
    distanceFilter: 25,
    timeLimit: timeLimit,
  );
}

/// Production implementation. Handles the permission prompt, gracefully
/// yields `null` when permission is denied or the GPS radio is off, and
/// filters stream updates so we don't wake consumers for sub-meter jitter.
///
/// On a head unit, GPS might be unavailable if the user didn't grant
/// location — the rest of the app keeps working; consumers just see a
/// "Location unavailable" state on the relevant tiles.
class GeolocatorLocationService implements LocationService {
  /// In-process cache of the latest stream fix, populated by the
  /// stream loop and read by [freshFix] so a session-mint that runs
  /// 30 s after the last update doesn't pay another GPS poll.
  /// ``null`` until the first fix arrives. Kept on the singleton
  /// because the location service is process-wide and the cache
  /// would otherwise be lost on every Riverpod stream resubscribe.
  LocationFix? _lastStreamFix;

  @override
  Future<LocationFix?> current() async {
    if (!await ensurePermission()) return null;
    // Android: take the first fix off the native chip stream — same path
    // as stream()/freshFix(). Keeps the whole Android location layer on the
    // raw GNSS provider and avoids Geolocator's fused one-shot, which on
    // some BYD ROMs returns a stale/empty cache (and churns useless fused
    // registrations).
    if (defaultTargetPlatform == TargetPlatform.android) {
      return _firstNativeFix(timeout: const Duration(seconds: 8));
    }
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: _buildLocationSettings(
          timeLimit: const Duration(seconds: 8),
        ),
      );
      return _toFix(pos);
    } catch (e) {
      if (kDebugMode) debugPrint('location: getCurrentPosition failed: $e');
      return null;
    }
  }

  /// First fix from the native chip stream ([_nativeAndroidStream]) under a
  /// hard [timeout], or null. When [notBefore] is set, a fix is only
  /// accepted if its timestamp is at-or-after it — used by [freshFix] to
  /// reject a replayed stale seed and guarantee a chip-fresh value. The
  /// single Android acquisition primitive: current(), freshFix()'s
  /// cache-miss fallback, all funnel here.
  Future<LocationFix?> _firstNativeFix({
    required Duration timeout,
    DateTime? notBefore,
  }) async {
    final completer = Completer<LocationFix?>();
    StreamSubscription<LocationFix>? sub;
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    try {
      sub = _nativeAndroidStream().listen(
        (fix) {
          if (notBefore != null &&
              fix.at != null &&
              fix.at!.isBefore(notBefore)) {
            return;
          }
          _lastStreamFix = fix;
          if (!completer.isCompleted) completer.complete(fix);
        },
        onError: (Object e) {
          if (kDebugMode) debugPrint('location: native fix error: $e');
          if (!completer.isCompleted) completer.complete(null);
        },
      );
      return await completer.future;
    } finally {
      timer.cancel();
      await sub?.cancel();
    }
  }

  @override
  Stream<LocationFix> stream() async* {
    if (!await ensurePermission()) return;
    // On Android we route through the native ``LocationBridge`` which
    // calls ``LocationManager.requestLocationUpdates`` directly —
    // same path Waze / Yandex Maps / Huawei Maps use on this BYD HU.
    // The geolocator package was confirmed broken here: even with
    // ``forceLocationManager: true`` + foreground service, our
    // subscription only registered under ``com.android.location.fused``
    // (Fused proxy) and we got the OS's stale 2-day-old cache instead
    // of fresh chip emissions. The native bridge appears in
    // ``dumpsys location`` ``gps provider`` listeners directly and
    // starts emitting fresh fixes within 1–3 s.
    if (defaultTargetPlatform == TargetPlatform.android) {
      yield* _nativeAndroidStream();
      return;
    }
    // Non-Android platforms keep using geolocator — the Fused-only
    // gotcha is BYD-HU-specific.
    await for (final pos in Geolocator.getPositionStream(
      locationSettings: _buildLocationSettings(),
    )) {
      final fix = _toFix(pos);
      _lastStreamFix = fix;
      yield fix;
    }
  }

  /// Reads the native EventChannel exposed by ``LocationBridge.kt``.
  /// Wire format (mirrors the Kotlin side verbatim):
  ///   * ok=true  → ``{lat, lng, accuracyM?, altitudeM?, bearingDeg?,
  ///     speedMps?, provider, timeMs}``
  ///   * ok=false → ``{ok: false, reason: 'no_fix' | 'no_permission'}``
  /// The latter is dropped from the stream — callers see absence of
  /// fix as a permission/service issue handled by ``ensurePermission``.
  static const _nativeChannel = EventChannel('ilink/location/stream');

  Stream<LocationFix> _nativeAndroidStream() async* {
    await for (final raw in _nativeChannel.receiveBroadcastStream()) {
      if (raw is! Map) continue;
      if (raw['ok'] != true) continue;
      final lat = (raw['lat'] as num?)?.toDouble();
      final lng = (raw['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      final accuracy = (raw['accuracyM'] as num?)?.toDouble();
      // bearingDeg / speedMps are emitted by LocationBridge.kt (null-guarded
      // on hasBearing/hasSpeed). A stationary fix often has no bearing and a
      // ~0 speed; treat negative/non-finite as "unknown".
      final bearing = (raw['bearingDeg'] as num?)?.toDouble();
      final speed = (raw['speedMps'] as num?)?.toDouble();
      final timeMs = raw['timeMs'] as int?;
      final fix = LocationFix(
        latitude: lat,
        longitude: lng,
        accuracyM: accuracy,
        headingDeg: (bearing != null && bearing.isFinite && bearing >= 0)
            ? bearing
            : null,
        speedMps: (speed != null && speed.isFinite && speed >= 0)
            ? speed
            : null,
        at: timeMs == null
            ? DateTime.now()
            : DateTime.fromMillisecondsSinceEpoch(timeMs),
      );
      _lastStreamFix = fix;
      yield fix;
    }
  }

  @override
  Future<LocationFix?> freshFix({
    Duration maxCacheAge = const Duration(minutes: 5),
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final cached = _lastStreamFix;
    if (cached != null && cached.at != null) {
      final age = DateTime.now().difference(cached.at!);
      if (age <= maxCacheAge) return cached;
    }
    if (!await ensurePermission()) return null;

    // Cache miss → acquire a fresh fix by subscribing and taking the FIRST
    // emission. Reason — both Geolocator's getCurrentPosition and
    // LocationManager.getLastKnownLocation read the OS's cached fix first;
    // on a parked car whose chip hasn't reacquired since the previous trip
    // that cache can be days old (or the wrong country). Subscribing nudges
    // the OS to power up the GNSS chip and emit a satellite-derived fix.
    //
    // CRITICAL on the BYD fleet: on Android we acquire through the **native
    // bridge** (raw GNSS chip), NOT Geolocator's position stream. Geolocator
    // routes through FusedLocationProviderClient, whose fused proxy is a dead
    // source on some BYD ROMs — so a cache-miss fallback via geolocator would
    // time out on exactly the cars where the keepalive never warmed the cache
    // (the same units where "nearby" silently fails). The native bridge binds
    // the gps provider directly, so a cold-cache acquire works fleet-wide.
    //
    // We discard a replayed cached value if it predates this call and wait
    // for the first fix whose timestamp is at-or-after the start — a
    // guarantee it came from the chip, not memory. The timeout is the hard
    // ceiling; past it we degrade to "no GPS" rather than block the mic.
    final startedAt = DateTime.now();

    // Android: the single native chip primitive (shared with current()).
    if (defaultTargetPlatform == TargetPlatform.android) {
      return _firstNativeFix(timeout: timeout, notBefore: startedAt);
    }

    // Non-Android: Geolocator's position stream is fine off the BYD fleet.
    final completer = Completer<LocationFix?>();
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    StreamSubscription<Position>? sub;
    try {
      sub =
          Geolocator.getPositionStream(
            locationSettings: _buildFreshFixSettings(timeout: timeout),
          ).listen(
            (pos) {
              final fix = _toFix(pos);
              if (fix.at != null && fix.at!.isBefore(startedAt)) return;
              _lastStreamFix = fix;
              if (!completer.isCompleted) completer.complete(fix);
            },
            onError: (Object e) {
              if (kDebugMode) debugPrint('location: freshFix stream error: $e');
              if (!completer.isCompleted) completer.complete(null);
            },
          );
      return await completer.future;
    } finally {
      timer.cancel();
      await sub?.cancel();
    }
  }

  /// Settings tuned for a *fresh* one-shot fix. Differs from
  /// [_buildLocationSettings] by forcing the GNSS chip path
  /// (``forceLocationManager: true``) so Android can't satisfy the
  /// request from a stale Fused cache, and bumping accuracy to
  /// [LocationAccuracy.high] so the OS prioritises a satellite
  /// solution over a Wi-Fi/cell triangulation.
  LocationSettings _buildFreshFixSettings({required Duration timeout}) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        forceLocationManager: true,
        timeLimit: timeout,
      );
    }
    return LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      timeLimit: timeout,
    );
  }

  @override
  Future<bool> ensurePermission() async {
    final serviceOn = await Geolocator.isLocationServiceEnabled();
    if (!serviceOn) return false;
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    return p == LocationPermission.always || p == LocationPermission.whileInUse;
  }

  @override
  Future<LocationPermissionOutcome> requestPermission() async {
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    switch (p) {
      case LocationPermission.always:
      case LocationPermission.whileInUse:
        return LocationPermissionOutcome.granted;
      case LocationPermission.denied:
      case LocationPermission.deniedForever:
        return LocationPermissionOutcome.denied;
      case LocationPermission.unableToDetermine:
        return LocationPermissionOutcome.unavailable;
    }
  }

  LocationFix _toFix(Position p) => LocationFix(
    latitude: p.latitude,
    longitude: p.longitude,
    accuracyM: p.accuracy,
    headingDeg: p.heading.isFinite && p.heading >= 0 ? p.heading : null,
    speedMps: p.speed.isFinite && p.speed >= 0 ? p.speed : null,
    at: p.timestamp,
  );
}

final locationServiceProvider = Provider<LocationService>((_) {
  return GeolocatorLocationService();
});

/// Current position, polled every minute and on-demand by consumers.
/// Returns `null` on denied/off/unavailable. Kept at app-scope so the
/// weather tile and the compass share one GPS subscription.
final currentLocationProvider = StreamProvider<LocationFix?>((ref) async* {
  final service = ref.watch(locationServiceProvider);
  // Emit once immediately so widgets don't sit in loading for the 25 m
  // first update threshold.
  yield await service.current();
  yield* service.stream();
});

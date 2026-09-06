# Media and installed mini-app network boundaries

Implemented 2026-09-06. Streaming consent gates the real radio adapter's
play/resume methods and the TV platform bridge before native playback. Disabling
it stops active radio HTTP playback and invokes the new native `tv_ivi.stop`
command, which stops the IVI player and passenger player. Native IVI startup and
cast completions also check that their playback session has not been revoked.
TV launch errors are presented without crashing the browser. Favorites,
playlist imports from local files, and local catalog/cache data remain intact.
Direct local audio files can play without streaming consent; local playlist
files still require consent because they can reference remote segments.

Installed mini-apps start from their existing local verified bundle. The
Downloads setting now also authorizes that app's declared network origins.
Without consent Android `blockNetworkLoads` is enabled; navigation, resource
interception and CSP additionally deny remote resources. Local resources must
remain under the installed bundle's directory; encoded parent traversal and
network file authorities are rejected. Data/blob resources remain usable.
WebSockets, EventSource, workers and service-worker registration are disabled
in offline documents; the existing WebRTC restriction remains.

Revoking Downloads stops the current WebView load and recreates its native
document with offline settings, closing old document sockets/workers. Existing
car subscriptions are drained before the new local document reconnects.
Persisted bundle data is retained; unsaved in-memory page state can be lost on
this explicit policy change. Mini-apps that depend on Web Workers must be
reviewed for offline compatibility; computational worker support has not been
device-validated under the restricted policy.

Automated validation: 228 tests passed across TV, radio, mini-app viewer,
origin policy and offline egress tests. New tests cover default-disabled native
TV dispatch, opt-in playback/stop, local bundle reads, traversal rejection,
network-origin consent and offline script restrictions. Native Android playback,
passenger casting and WebView network behavior need physical-device verification;
the Dart tests do not prove platform cancellation of every transport.

## Passenger entry and cross-process consent follow-up

`TvPassengerPlugin` references were stale documentation: no such plugin or
Flutter caller remains. The exported `PassengerPlayerActivity` can still receive
direct shell intents, so its native startup and each new playback intent now
check `StreamingPolicy` before constructing media sources. `PassengerLauncher`
and the IVI plugin enforce the same policy. The root preferences adapter mirrors
durable streaming consent through `tv_ivi.setStreamingEnabled` to an atomic
device-local flag, read afresh by the isolated passenger process. Missing or
unreadable policy is disabled.

HTTP data sources recheck consent before connection and during reads, so a
subsequent HLS segment cannot restart a revoked session. Disabling sends stop
broadcasts even when the Flutter TV provider was never initialized. Direct local
media uses `DefaultDataSource`; network-only revoke broadcasts leave direct
local playback available. Local playlists still require streaming consent.

Follow-up verification: 42 focused TV/local-media tests passed and focused Dart
analysis passed. Native compilation was requested from the Android validation
agent; device casting/revocation checks remain pending.

Official platform references checked 2026-09-06:
[Android WebSettings](https://developer.android.com/reference/android/webkit/WebSettings#setBlockNetworkLoads(boolean))
and [InAppWebView settings](https://inappwebview.dev/docs/webview/in-app-weview-settings/).

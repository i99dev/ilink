/// Push channel from a family handler back to the mini-app's
/// JavaScript world. Subscribe handlers (`display.subscribe`,
/// `surface.subscribe`, future `pkg.subscribe`, …) take a [BridgeCall]
/// that carries one of these and call [pushEvent] for every native
/// event they want to forward.
///
/// Production impl wraps `evaluateJavascript('window.__i99dashEvents
/// .dispatch(channel, payload)')`; tests use [FakeFamilyEventPusher].
///
/// The SDK side (`sdk-ilink/packages/sdk/src/bridge.ts`) already
/// owns the `__i99dashEvents` global and the `on(channel, handler)`
/// API the legacy `car.status.subscribe` flow uses. New families
/// pick a channel name (`display`, `surface`, …) and reuse that
/// dispatcher — no SDK-side change beyond a typed
/// `controller.onChange(cb)` wrapper that subscribes to the family
/// channel.
library;

/// Minimal interface — one method, JSON-only payloads.
///
/// Implementations MUST be idempotent against post-disposal calls
/// (the WebView controller can tear down between an EventChannel
/// pump and the JS hop). The production impl null-checks the
/// controller; the fake just records calls.
abstract class FamilyEventPusher {
  /// Forward a native event to the mini-app's JS world.
  ///
  /// [channel] is the SDK-facing channel name — by convention the
  /// `familyId` (e.g. `'display'`). [payload] is the JSON-encodable
  /// event body the SDK's listener receives verbatim.
  ///
  /// Errors during marshal / evaluate are swallowed: a torn-down
  /// WebView mid-stream is the common case, not a programmer bug.
  /// Implementations log loudly when the controller is missing
  /// outright (vs. transient).
  void pushEvent(String channel, Map<String, Object?> payload);
}

/// In-memory fake for unit tests. Records every call so the test
/// can assert order + payload shape; never marshals to JSON / JS.
///
/// Use:
///
///     final pusher = FakeFamilyEventPusher();
///     final fam = DisplayFamily(bridge: fakeBridge);
///     await fam.handlers['subscribe']!.execute(BridgeCall(
///       …, eventPusher: pusher,
///     ));
///     // emit on fakeBridge.events()
///     expect(pusher.events, hasLength(1));
class FakeFamilyEventPusher implements FamilyEventPusher {
  final List<({String channel, Map<String, Object?> payload})> events = [];

  @override
  void pushEvent(String channel, Map<String, Object?> payload) {
    events.add((channel: channel, payload: payload));
  }

  /// Clear recorded events between assertions in long-lived
  /// fixtures.
  void clear() => events.clear();
}

/// No-op pusher for legacy call sites that don't subscribe to
/// anything. Lets [FamilyExecutor] always pass a non-null pusher
/// without each caller threading "but I don't subscribe" through.
class NoopFamilyEventPusher implements FamilyEventPusher {
  const NoopFamilyEventPusher();

  @override
  void pushEvent(String channel, Map<String, Object?> payload) {}
}

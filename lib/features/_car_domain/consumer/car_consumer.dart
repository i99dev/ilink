import 'package:flutter/foundation.dart';

import '../../../sdk/car/car_caller.dart';

/// Identity of a caller asking for car data or dispatching commands.
/// Sealed — only the kinds defined here exist, so the security-bridge
/// audit log has a closed set of cases to handle.
///
/// Extends [CarCaller] so any [CarConsumer] satisfies the SDK's
/// dispatch surface — `client.dispatch(..., caller: HostUiConsumer.instance)`
/// works without an extra adapter. The SDK only sees [kindLabel].
///
/// Adding a new kind: extend the sealed class and declare its
/// [kindLabel].
///
/// Scope semantics (the previous `allowedScopes` field) were removed
/// with the v2 mini-app bridge — read access is no longer scoped per
/// consumer. Writes still gate through `CarCommandRouter`'s integrity
/// / rate-limit / stationary checks, identified by [kindLabel] alone.
@immutable
sealed class CarConsumer extends CarCaller {
  const CarConsumer();

  /// Stable identifier used in security-bridge logs. Lowercase
  /// snake_case, must match the regex `[a-z][a-z0-9_]*` so log
  /// aggregators don't have to quote-escape it.
  @override
  String get kindLabel;
}

/// In-process host UI: home screen tiles, settings panels, dev bench
/// (when `devCarControlsEnabled` is on). Same trust level as the
/// dashboard process itself.
class HostUiConsumer extends CarConsumer {
  const HostUiConsumer._();
  static const HostUiConsumer instance = HostUiConsumer._();

  @override
  String get kindLabel => 'host_ui';
}

/// Voice / assistant tool router. Production mode (`devCarControlsEnabled`
/// off) and dev mode are now identical at the consumer layer — the
/// SDK trusts the kind label and routes via the command router's
/// gates. Dev-mode awareness stays on the field so the audit log
/// can still distinguish dev runs from production.
class VoiceConsumer extends CarConsumer {
  const VoiceConsumer({required this.devModeEnabled});
  final bool devModeEnabled;

  @override
  String get kindLabel => 'voice';

  @override
  bool operator ==(Object other) =>
      other is VoiceConsumer && other.devModeEnabled == devModeEnabled;

  @override
  int get hashCode => devModeEnabled.hashCode;
}

/// Standard mini-app — identified by its [appId] for audit chaining.
/// Manifest-derived scope sets used to live here; they're gone with
/// the v2 bridge ("Read = always allowed").
class MiniAppStandardConsumer extends CarConsumer {
  const MiniAppStandardConsumer({required this.appId});
  final String appId;

  @override
  String get kindLabel => 'mini_app_standard';

  @override
  bool operator ==(Object other) =>
      other is MiniAppStandardConsumer && other.appId == appId;

  @override
  int get hashCode => appId.hashCode;
}

/// Privileged / admin mini-app op. Carries the template id for audit
/// chaining.
class MiniAppAdminConsumer extends CarConsumer {
  const MiniAppAdminConsumer({required this.templateId});
  final String templateId;

  @override
  String get kindLabel => 'mini_app_admin';

  @override
  bool operator ==(Object other) =>
      other is MiniAppAdminConsumer && other.templateId == templateId;

  @override
  int get hashCode => templateId.hashCode;
}

/// Backend MQTT uplink publisher.
class MqttUplinkConsumer extends CarConsumer {
  const MqttUplinkConsumer._();
  static const MqttUplinkConsumer instance = MqttUplinkConsumer._();

  @override
  String get kindLabel => 'mqtt_uplink';
}

/// Phone-issued command from the Telegram miniapp, delivered over
/// the ``cars/{vin}/cmd`` MQTT downlink. Distinct ``kindLabel`` from
/// [TunnelConsumer] so the audit log can separate phone taps from a
/// hypothetical browser companion. Rate-limit bucket is shared with
/// [VoiceConsumer] inside [RateLimiter] — phone bursts must not
/// starve voice.
class MqttPhoneConsumer extends CarConsumer {
  const MqttPhoneConsumer._();
  static const MqttPhoneConsumer instance = MqttPhoneConsumer._();

  @override
  String get kindLabel => 'mqtt_phone';
}

/// Remote tunnel session (driver companion app). Same trust level as
/// MQTT uplink but rate-limited separately — tunnel reads are
/// human-driven (refresh, panel switch) so the burst pattern differs.
class TunnelConsumer extends CarConsumer {
  const TunnelConsumer({required this.sessionId});
  final String sessionId;

  @override
  String get kindLabel => 'tunnel';

  @override
  bool operator ==(Object other) =>
      other is TunnelConsumer && other.sessionId == sessionId;

  @override
  int get hashCode => sessionId.hashCode;
}

/// Workflow engine — a user-authored automation firing in the
/// background (no human present at the moment of dispatch). Carries the
/// [workflowId] for audit chaining. Distinct [kindLabel] so the audit
/// log can separate automation-driven commands from human taps/voice;
/// the engine applies its OWN stationary/confirm gate for
/// safety/security-class actions BEFORE this reaches the router.
class AutomationConsumer extends CarConsumer {
  const AutomationConsumer({required this.workflowId});
  final String workflowId;

  @override
  String get kindLabel => 'automation';

  @override
  bool operator ==(Object other) =>
      other is AutomationConsumer && other.workflowId == workflowId;

  @override
  int get hashCode => workflowId.hashCode;
}

/// Dev test bench — same access as host UI but logs separately so we
/// can tell test-bench reads apart from production UI reads in audit.
/// Construction is gated by the `devCarControlsEnabled` setting at the
/// callsite; the gate itself trusts the type.
class DevBenchConsumer extends CarConsumer {
  const DevBenchConsumer._();
  static const DevBenchConsumer instance = DevBenchConsumer._();

  @override
  String get kindLabel => 'dev_bench';
}

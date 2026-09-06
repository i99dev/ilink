import 'package:flutter/material.dart';

import '../../../kernel/ui/theme/colors.dart';
import '../command/command.dart';

/// Window / sunroof command fragment.
///
/// **Pattern: per-pane verb-fan-out via [_winCmd] helper.** The wire
/// has one action per pane (`window.fl/rf/rl/rr`) that takes a single
/// `value` enum (open=1, close=2, stop=0, down=3) — N verbs per pane,
/// 1 wire action per pane. The catalog-driven builder
/// ([bydCatalogCommands]) assumes 1:1 catalog → command and doesn't
/// fit this shape. The [_winCmd] helper IS the centralised pattern
/// for verb-fanned commands: one row per (pos, verb) tuple, the
/// helper closes over the resolve-to-value mapping.
///
/// Each physical window exposes four discrete actions (open / close / stop /
/// down) as separate registry ids, and they all collapse into a single
/// `window_control` voice tool via [CarCommand.voiceGroup]. UI still reaches
/// the atomic ids (`window.fl.open`) — only the voice manifest sees the
/// grouped shape (`window_control(window: fl, action: open)`).
///
/// ## Wire mapping (Phase 1 bridge)
///
/// The textproto declares one `window.<pos>` action per physical pane and
/// dispatches an integer `value` that selects the actuator verb. The
/// registry namespace splits the verb back out into per-verb ids so the
/// UI can render four distinct buttons and the voice manifest can list
/// individual actions. Each per-verb id `resolve:`s back to the single
/// `window.<pos>` wire id with the right integer.
///
///   * positional rename: `fr` (Dart) → `rf` (textproto, BODYWORK_RF_…)
///   * verb→value:        open=1 · close=2 · stop=0 · down=3
///
/// Sources of truth:
///   * verb enum:  `testing_case/unit/window/README.md` + this file's
///     [_verbValue] map (must agree).
///   * wire action_id: `.secrets/car_table/car_table.textproto` —
///     `fast_actions { action_id: "window.<pos>" }`.
///
/// Phase 2 (textproto rename to per-verb action_ids) deletes the
/// `_verbValue` indirection. Until then [registry_wire_parity_test]
/// validates each resolved actionId against the textproto.
const _windowGroup = 'window_control';
const _windowIdTemplate = 'window.{window}.{action}';
const _windowGroupParams = {
  'window': 'fl | fr | rl | rr | all',
  'action': 'open | close | stop | down',
};
const _windowGroupDescription =
    'Control a single window or all windows at once. '
    'Examples: "roll down the driver window" → window=fl, action=open. '
    '"Close all windows" → window=all, action=close. '
    '"Stop the passenger window" → window=fr, action=stop. '
    '"Drop the driver window all the way down" → window=fl, action=down. '
    'The "down" action is only valid for the driver window (fl); '
    'the "stop" action is not valid for "all".';

const _sunroofGroup = 'sunroof_control';
const _sunroofIdTemplate = 'sunroof.{action}';
const _sunroofGroupParams = {'action': 'open | close | tilt | stop'};
const _sunroofGroupDescription =
    'Control the sunroof. action=open slides it back, close seals it, '
    'tilt pops the rear edge up for ventilation, stop halts motion. '
    'Examples: "open the sunroof" → action=open. "Tilt the sunroof" '
    '→ action=tilt.';

/// Verb → BODY-window value enum. Source: `testing_case/unit/window/`.
const _verbValue = <String, int>{'open': 1, 'close': 2, 'stop': 0, 'down': 3};

/// Dart-side position → textproto position. The textproto uses LF/RF/LR/RR
/// (framework-channel naming), the Dart side uses driver-relative fl/fr/rl/rr.
const _wirePosition = <String, String>{
  'fl': 'fl',
  'fr': 'rf',
  'rl': 'rl',
  'rr': 'rr',
};

/// Per-position button colour for the "open" verb. Stop tiles get
/// `neutral`, close tiles get `primary` regardless of position.
const _openColor = AppColors.accent;
const _closeColor = AppColors.primary;
const _stopColor = AppColors.neutral;
const _downColor = AppColors.warning;

CarCommand _winCmd({
  required String pos,
  required String posLabel,
  required String verb,
}) {
  final wirePos = _wirePosition[pos]!;
  final value = _verbValue[verb]!;
  return CarCommand(
    id: 'window.$pos.$verb',
    label: '$posLabel ${verb.toUpperCase()}',
    icon: switch (verb) {
      'open' => Icons.arrow_upward_rounded,
      'close' => Icons.arrow_downward_rounded,
      'stop' => Icons.stop_rounded,
      'down' => Icons.keyboard_double_arrow_down_rounded,
      _ => Icons.help_outline,
    },
    color: switch (verb) {
      'open' || 'down' => verb == 'down' ? _downColor : _openColor,
      'close' => _closeColor,
      'stop' => _stopColor,
      _ => _stopColor,
    },
    category: CommandCategory.window,
    requiresStationary: verb == 'open' || verb == 'down',
    voiceGroup: _windowGroup,
    voiceIdTemplate: _windowIdTemplate,
    voiceGroupParams: _windowGroupParams,
    voiceDescription: _windowGroupDescription,
    // Phase 1 wire bridge: one textproto action per pane (window.<wirePos>)
    // takes a single int `value` enum. We pass-through any caller args
    // (none today) but always set `value` to the verb's enum.
    resolve: (args) =>
        (actionId: 'window.$wirePos', args: {...args, 'value': value}),
  );
}

CarCommand _aggregateCmd({
  required String verb,
  required IconData icon,
  required Color color,
}) {
  // window.all.* has NO wire action_id yet — no `window.all` row in the
  // textproto, no macro that fans out to the four panes. Dispatch will
  // fail with `tool_not_found` until Phase 2 ships either a macro or
  // a client-side fan-out. Exempted from the parity test via
  // `_knownDartOnly`.
  return CarCommand(
    id: 'window.all.$verb',
    label: 'ALL WINDOWS ${verb.toUpperCase()}',
    icon: icon,
    color: color,
    category: CommandCategory.window,
    requiresStationary: verb == 'open',
    voiceGroup: _windowGroup,
    voiceIdTemplate: _windowIdTemplate,
    voiceGroupParams: _windowGroupParams,
    voiceDescription: _windowGroupDescription,
  );
}

// Window/sunroof commands change a position the driver can reverse with a
// follow-up tool call. Bulk-mark reversible for predictive execution.
// (Stationary-only safety check still applies before the action runs —
// predictive doesn't bypass it.)
//
// Every pane/verb is securityClass.safety: a moving window can pinch, so
// a BACKGROUND automation trigger must be stationary-gated by the engine
// regardless of the per-verb requiresStationary flag (which deliberately
// leaves close/stop ungated for human-initiated taps/voice). reversible
// is about voice prediction and is NOT a safety signal — hence the
// separate, explicit class.
final List<CarCommand> windowCommands = _windowsRaw
    .map((c) => c.withReversible(true).withSecurityClass(SecurityClass.safety))
    .toList(growable: false);

final List<CarCommand> _windowsRaw = [
  // ── Driver (front-left) — has the extra `down` verb ──
  _winCmd(pos: 'fl', posLabel: 'DRV WINDOW', verb: 'open'),
  _winCmd(pos: 'fl', posLabel: 'DRV WINDOW', verb: 'close'),
  _winCmd(pos: 'fl', posLabel: 'DRV WINDOW', verb: 'stop'),
  _winCmd(pos: 'fl', posLabel: 'DRV WINDOW', verb: 'down'),

  // ── Co-driver (front-right) ──
  _winCmd(pos: 'fr', posLabel: 'PASS WINDOW', verb: 'open'),
  _winCmd(pos: 'fr', posLabel: 'PASS WINDOW', verb: 'close'),
  _winCmd(pos: 'fr', posLabel: 'PASS WINDOW', verb: 'stop'),

  // ── Rear-left ──
  _winCmd(pos: 'rl', posLabel: 'REAR L WINDOW', verb: 'open'),
  _winCmd(pos: 'rl', posLabel: 'REAR L WINDOW', verb: 'close'),
  _winCmd(pos: 'rl', posLabel: 'REAR L WINDOW', verb: 'stop'),

  // ── Rear-right ──
  _winCmd(pos: 'rr', posLabel: 'REAR R WINDOW', verb: 'open'),
  _winCmd(pos: 'rr', posLabel: 'REAR R WINDOW', verb: 'close'),
  _winCmd(pos: 'rr', posLabel: 'REAR R WINDOW', verb: 'stop'),

  // ── Aggregate (no wire yet) ──
  _aggregateCmd(
    verb: 'open',
    icon: Icons.unfold_more_rounded,
    color: _openColor,
  ),
  _aggregateCmd(
    verb: 'close',
    icon: Icons.unfold_less_rounded,
    color: _closeColor,
  ),

  // ── Sunroof (separate group) — same drift as window.all: registry uses
  //    `sunroof.open|close|tilt|stop`, textproto exposes only
  //    `sunroof.ctl` (single action with value enum) and
  //    `sunroof.percent`. The verb-enum integers for `sunroof.ctl`
  //    aren't yet ground-truthed in this repo, so leave these
  //    dispatch-broken until someone confirms the framework values —
  //    `_knownDartOnly` exempts them from the parity test. ───
  const CarCommand(
    id: 'sunroof.open',
    label: 'SUNROOF OPEN',
    icon: Icons.wb_sunny_rounded,
    color: _openColor,
    category: CommandCategory.window,
    requiresStationary: true,
    voiceGroup: _sunroofGroup,
    voiceIdTemplate: _sunroofIdTemplate,
    voiceGroupParams: _sunroofGroupParams,
    voiceDescription: _sunroofGroupDescription,
  ),
  const CarCommand(
    id: 'sunroof.close',
    label: 'SUNROOF CLOSE',
    icon: Icons.wb_sunny_outlined,
    color: _closeColor,
    category: CommandCategory.window,
    voiceGroup: _sunroofGroup,
    voiceIdTemplate: _sunroofIdTemplate,
    voiceGroupParams: _sunroofGroupParams,
    voiceDescription: _sunroofGroupDescription,
  ),
  const CarCommand(
    id: 'sunroof.tilt',
    label: 'SUNROOF TILT',
    icon: Icons.blinds_closed_rounded,
    color: _downColor,
    category: CommandCategory.window,
    requiresStationary: true,
    voiceGroup: _sunroofGroup,
    voiceIdTemplate: _sunroofIdTemplate,
    voiceGroupParams: _sunroofGroupParams,
    voiceDescription: _sunroofGroupDescription,
  ),
  const CarCommand(
    id: 'sunroof.stop',
    label: 'SUNROOF STOP',
    icon: Icons.stop_rounded,
    color: _stopColor,
    category: CommandCategory.window,
    voiceGroup: _sunroofGroup,
    voiceIdTemplate: _sunroofIdTemplate,
    voiceGroupParams: _sunroofGroupParams,
    voiceDescription: _sunroofGroupDescription,
  ),
];

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/nav_hud_controller.dart';
import '../data/nav_hud_bridge.dart';

/// The Nav-HUD activation + status panel. A status-first redesign of the reference's
/// flat preference list: a hero card that says at a glance whether the HUD is
/// live and on which transport, then the app picker + option toggles.
///
/// The single Nav-HUD UI — hosted by [NavHudSheet] from the home Tools strip
/// (the "pin" circle). No longer embedded in Settings.
class NavHudPanel extends ConsumerWidget {
  const NavHudPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(navHudControllerProvider);
    final ctrl = ref.read(navHudControllerProvider.notifier);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // The essentials, top to bottom: is it on, what's it doing, which app,
        // and the two everyday toggles. Everything technical lives under Advanced.
        _HeroCard(state: state, onToggle: ctrl.setEnabled),
        if (state.armed) ...[
          const SizedBox(height: 12),
          _StatusCard(status: state.status),
        ],
        const SizedBox(height: 20),
        const _SectionLabel('Navigation app'),
        _AppPicker(pinned: state.pinned, onPick: ctrl.pin),
        const SizedBox(height: 16),
        _OptionTile(
          icon: Icons.play_circle_outline,
          title: 'Start with navigation',
          subtitle: 'Show the cluster HUD automatically when you navigate',
          value: state.options.autoStart,
          onChanged: (v) => ctrl.setOption('autoStart', v),
        ),
        _OptionTile(
          icon: Icons.translate,
          title: 'Transliterate road names',
          subtitle: 'Fold non-Latin names to Latin for the cluster',
          value: state.options.transliterate,
          onChanged: (v) => ctrl.setOption('transliterate', v),
        ),
        const SizedBox(height: 8),
        _AdvancedSection(state: state, ctrl: ctrl),
        if (!state.probe.any) ...[
          const SizedBox(height: 12),
          const _InfoNote(
            'No cluster transport detected yet on this car. Verify on-device '
            '(M0): the SOME/IP service bind + the BYD instrument HAL.',
          ),
        ],
      ],
    );
  }
}

/// Everything technical, tucked behind one tap so the panel stays simple:
/// transport probe + re-probe, the test maneuver, the niche feature toggles, and
/// the cluster-protocol override. Collapsed by default — most users never open it.
class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({required this.state, required this.ctrl});
  final NavHudState state;
  final NavHudController ctrl;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        leading: const Icon(Icons.tune),
        title: const Text('Advanced'),
        children: [
          _TransportRow(
            probe: state.probe,
            onRefresh: ctrl.refresh,
            busy: state.busy,
          ),
          if (state.armed) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: ctrl.sendTest,
                icon: const Icon(Icons.bolt, size: 18),
                label: const Text('Send test maneuver'),
              ),
            ),
          ],
          _OptionTile(
            icon: Icons.warning_amber_rounded,
            title: 'Speed-camera & police alerts',
            subtitle: 'Show Waze alerts on the cluster safety glyph',
            value: state.options.cameraAlerts,
            onChanged: (v) => ctrl.setOption('cameraAlerts', v),
          ),
          _OptionTile(
            icon: Icons.dashboard_customize_outlined,
            title: 'Native dashboard widget',
            subtitle: 'Also drive BYD\'s built-in map widget',
            value: state.options.amapWidget,
            onChanged: (v) => ctrl.setOption('amapWidget', v),
          ),
          const SizedBox(height: 12),
          const _SectionLabel('Cluster protocol'),
          const SizedBox(height: 6),
          _ProtocolPicker(
            value: state.options.clusterProtocol,
            onPick: ctrl.setClusterProtocol,
          ),
          const SizedBox(height: 12),
          const _SectionLabel('SOME/IP wire variant'),
          const SizedBox(height: 6),
          _VariantPicker(
            value: state.options.someIpVariant,
            resolved: state.options.someIpVariantResolved,
            onPick: ctrl.setSomeIpVariant,
          ),
        ],
      ),
    );
  }
}

/// Cluster-protocol override. Default **Auto** drives every available transport at
/// once (SOME/IP + CAN-FID + Amap) so the cluster renders whichever it reads —
/// needed because trims with the same `ro.vehicle.type` can read different
/// protocols. Force **SOME/IP** or **CAN-FID** to diagnose a stubborn car.
class _ProtocolPicker extends StatelessWidget {
  const _ProtocolPicker({required this.value, required this.onPick});
  final String value;
  final ValueChanged<String> onPick;

  static const _opts = <String, String>{
    'auto': 'Auto (all)',
    'someip': 'SOME/IP',
    'canfid': 'CAN-FID',
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: _opts.entries
              .map(
                (e) => ChoiceChip(
                  label: Text(e.value),
                  selected: value == e.key,
                  onSelected: (_) => onPick(e.key),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 6),
        Text(
          'Auto sends to every channel this cluster might read. Switch only if the '
          'HUD stays blank — then try CAN-FID.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// SOME/IP wire-variant override — the **revert switch**.
///
/// **Auto** derives the variant from the detected car model; **UI7** forces the
/// wire we ship and have proven on a car today. Because cluster behaviour can
/// only ever be judged on a real car, a tester must be able to get back to known-
/// good behaviour by flipping this — no rebuild, no reinstall. Picking UI7 is
/// that flip, and it stays pinned even if a future build changes what Auto picks.
class _VariantPicker extends StatelessWidget {
  const _VariantPicker({
    required this.value,
    required this.resolved,
    required this.onPick,
  });
  final String value;

  /// What `auto` actually resolved to — shown so the tester can tell an explicit
  /// override apart from a default that happens to agree with it.
  final String resolved;
  final ValueChanged<String> onPick;

  static const _opts = <String, String>{
    'auto': 'Auto (by model)',
    'ui7': 'UI7 (proven)',
    // TASK-016. Surfaced so the on-car probe is a tap rather than an adb prefs
    // edit, and labelled so nobody mistakes it for a supported mode. It is never
    // a default — `auto` cannot resolve to it on any model.
    'launcher_map_cn': 'Launcher map (unproven)',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: _opts.entries
              .map(
                (e) => ChoiceChip(
                  label: Text(e.value),
                  selected: value == e.key,
                  onSelected: (_) => onPick(e.key),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 6),
        Text(
          value == 'auto'
              ? 'Auto picked "$resolved" for this car. Pick UI7 to pin the '
                    'cluster to the wire we ship today — use it to undo any HUD '
                    'change without reinstalling.'
              : value == 'launcher_map_cn'
              ? 'Experimental: drives the launcher map widget over 11 topics. '
                    'NOT verified on this car — the map may be mispositioned or '
                    'may not appear. Guidance is unaffected. Switch to UI7 to go '
                    'back to the known-good wire immediately.'
              : 'Pinned to "$resolved". This is the known-good wire; switch back '
                    'to Auto to follow the per-model default again.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.state, required this.onToggle});
  final NavHudState state;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // "Live" = actually linked (the native bind), not just the optimistic armed
    // flag. Armed-but-not-linked shows "Connecting…".
    final live = state.armed && state.status.connected;
    final base = live ? cs.primary : cs.surfaceContainerHighest;
    final on = live ? cs.onPrimary : cs.onSurfaceVariant;
    final transportLabel = switch (state.status.transport) {
      'SOME_IP' => 'SOME/IP (ADB-free)',
      'CAN_FID' => 'HAL',
      _ => state.probe.adbFree ? 'SOME/IP (ADB-free)' : 'HAL',
    };

    return Card(
      elevation: 0,
      color: base,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: on.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(Icons.navigation_rounded, color: on, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Cluster Nav-HUD',
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(color: on),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    !state.probe.any
                        ? 'No transport available'
                        : !state.armed
                        ? 'Ready · tap to start'
                        : live
                        ? 'Live · $transportLabel'
                        : 'Connecting…',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: on.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: state.armed,
              onChanged: state.probe.any && !state.busy ? onToggle : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Live runtime status (shown while armed) — the on-car diagnostics surface:
/// did the SOME/IP bind succeed, which app is driving, is data flowing.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});
  final NavHudStatus status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final linked = status.connected;
    final tName = switch (status.transport) {
      'SOME_IP' => 'SOME/IP (ADB-free)',
      'CAN_FID' => 'BYD HAL',
      null || '' => 'selecting…',
      // Drive-all shows the joined set, e.g. "SOME_IP+CAN_FID".
      final t =>
        t.replaceAll('SOME_IP', 'SOME/IP').replaceAll('CAN_FID', 'HAL'),
    };
    final hasFrame = status.maneuver != null && status.distanceMeters != null;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                linked ? Icons.link : Icons.link_off,
                size: 18,
                color: linked ? Colors.green : cs.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  linked ? 'Linked · $tName' : 'Transport $tName · not linked',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Text(
                '${status.pushed} frames',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            status.drivingApp == null
                ? 'Waiting for a navigation app…'
                : 'Driving: ${_appLabel(status.drivingApp!)}'
                      '${hasFrame ? '  ·  maneuver ${status.maneuver}  ·  ${status.distanceMeters} m' : ''}'
                      '${(status.road?.isNotEmpty ?? false) ? '  ·  ${status.road}' : ''}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  String _appLabel(String id) => switch (id) {
    'GOOGLE_MAPS' => 'Google Maps',
    'WAZE' => 'Waze',
    'YANDEX' => 'Yandex',
    'AMAP' => 'Amap',
    'UNKNOWN' => 'app',
    _ => id.toLowerCase().replaceAll('_', ' '),
  };
}

class _TransportRow extends StatelessWidget {
  const _TransportRow({
    required this.probe,
    required this.onRefresh,
    required this.busy,
  });
  final HudTransportProbe probe;
  final VoidCallback onRefresh;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _TransportChip(label: 'SOME/IP', sub: 'ADB-free', ok: probe.someip),
        const SizedBox(width: 8),
        _TransportChip(label: 'CAN-FID', sub: 'HAL', ok: probe.canfid),
        const Spacer(),
        IconButton(
          tooltip: 'Re-probe',
          onPressed: busy ? null : onRefresh,
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        ),
      ],
    );
  }
}

class _TransportChip extends StatelessWidget {
  const _TransportChip({
    required this.label,
    required this.sub,
    required this.ok,
  });
  final String label;
  final String sub;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = ok ? Colors.green : cs.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.remove_circle_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
          Text('$label · $sub', style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }
}

class _AppPicker extends StatelessWidget {
  const _AppPicker({required this.pinned, required this.onPick});
  final NavApp? pinned;
  final ValueChanged<NavApp?> onPick;

  static const _apps = <NavApp?, String>{
    null: 'Auto',
    NavApp.googleMaps: 'Google Maps',
    NavApp.waze: 'Waze',
    NavApp.yandex: 'Yandex',
    NavApp.amap: 'Amap',
  };

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _apps.entries
          .map(
            (e) => ChoiceChip(
              label: Text(e.value),
              selected: pinned == e.key,
              onSelected: (_) => onPick(e.key),
            ),
          )
          .toList(),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _InfoNote extends StatelessWidget {
  const _InfoNote(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

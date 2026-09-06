import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../kernel/ui/theme/colors.dart';
import '../../../../platform/network/connectivity_provider.dart';
import '../../../../platform/network/preferred_network_mode.dart';
import '../../domain/connectivity_state.dart';
import '../../state/connectivity_controller.dart';
import '../../state/connectivity_state_provider.dart';

/// Bottom sheet shown when the Network circle is tapped.
///
/// Matches Saqr's "Control" tab content pattern: one row per
/// capability, each row collapsible. Replaces five separate sheets so
/// users get one view of "what's my connectivity right now."
class NetworkModeSheet extends ConsumerWidget {
  const NetworkModeSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final async = ref.watch(connectivityStateProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                title: s.toolsNetworkLabel,
                onRefresh: () =>
                    ref.read(connectivityStateProvider.notifier).refresh(),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: async.when(
                    loading: () => const Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (e, _) => Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text('$e', style: TextStyle(color: cs.error)),
                    ),
                    data: (state) => _Rows(state: state),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onRefresh});
  final String title;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.refresh_rounded),
          tooltip: S.of(context).toolsNetworkRefresh,
          onPressed: onRefresh,
        ),
      ],
    );
  }
}

class _Rows extends ConsumerWidget {
  const _Rows({required this.state});
  final ConnectivityState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    return Column(
      children: [
        _Row(
          icon: Icons.wifi_rounded,
          label: s.toolsNetworkWifi,
          subtitle: state.wifi == NetState.on
              ? (state.wifiSsid ?? s.toolsNetworkWifiOnNoSsid)
              : s.toolsNetworkWifiOff,
          state: state.wifi,
          rssi: state.wifiRssi,
          onChanged: (on) => ref
              .read(connectivityControllerProvider.notifier)
              .toggleWifi(on ? NetState.on : NetState.off),
        ),
        const _Sep(),
        _Row(
          icon: Icons.signal_cellular_alt_rounded,
          label: s.toolsNetworkCellular,
          subtitle: state.cellular == NetState.on
              ? (state.cellularGeneration ?? s.toolsNetworkCellularOn)
              : s.toolsNetworkCellularOff,
          state: state.cellular,
          onChanged: (on) => ref
              .read(connectivityControllerProvider.notifier)
              .toggleCellular(on ? NetState.on : NetState.off),
        ),
        const _Sep(),
        _Row(
          icon: Icons.public_rounded,
          label: s.toolsNetworkRoaming,
          subtitle: state.roaming == NetState.on
              ? s.toolsNetworkRoamingOn
              : s.toolsNetworkRoamingOff,
          state: state.roaming,
          onChanged: (on) => ref
              .read(connectivityControllerProvider.notifier)
              .toggleRoaming(on ? NetState.on : NetState.off),
        ),
        const _Sep(),
        _Row(
          icon: Icons.bluetooth_rounded,
          label: s.toolsNetworkBluetooth,
          subtitle: state.bluetooth == NetState.on
              ? (state.btConnectedDevice ?? s.toolsNetworkBluetoothOnNoDevice)
              : s.toolsNetworkBluetoothOff,
          state: state.bluetooth,
          onChanged: (on) => ref
              .read(connectivityControllerProvider.notifier)
              .toggleBluetooth(on ? NetState.on : NetState.off),
        ),
        const _Sep(),
        _Row(
          icon: Icons.wifi_tethering_rounded,
          label: s.toolsNetworkHotspot,
          subtitle: state.hotspot == NetState.on
              ? s.toolsNetworkHotspotOn
              : s.toolsNetworkHotspotOff,
          state: state.hotspot,
          onChanged: (on) => ref
              .read(connectivityControllerProvider.notifier)
              .toggleHotspot(on ? NetState.on : NetState.off),
        ),
        const _Sep(),
        const _PreferredModePicker(),
      ],
    );
  }
}

/// Force the radio onto a specific generation (Auto / 5G / 4G / 3G /
/// 2G). Tapping a chip calls `forceApply`, which drives the
/// privileged headless `cmd phone
/// set-allowed-network-types-for-users` (with the mode's allowed-
/// types bitmask) over the shell-UID
/// bridge so the change hits the modem immediately (no airplane-mode
/// reload, no bridge drop); it also keeps
/// `Settings.Global.preferred_network_mode` written so the chip
/// highlight + the `settings get` poller stay coherent. If the ROM
/// refuses the headless call it falls back to opening the
/// `com.android.phone` RadioInfo Activity for manual apply.
///
/// Why this lives on the home-page Network sheet and not in
/// Settings: the previous Settings section that hosted this picker
/// was orphan code (never registered in `settingsSectionRegistry`),
/// so users couldn't reach it. This consolidates the radio-control
/// surface area into the one place users actually open.
class _PreferredModePicker extends ConsumerWidget {
  const _PreferredModePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final asyncMode = ref.watch(preferredNetworkModeProvider);
    final currentId = asyncMode.value;
    // Live generation (`4G` / `2G` / null). Distinct from `currentId`:
    // `currentId` is what the user PREFERRED (Auto → 9, 4G-only → 11,
    // etc.); `liveGen` is what the radio is ACTUALLY camped on right
    // now, which can differ if the carrier downshifts or the preferred
    // mode was Auto. Both signals matter — the chip highlights the
    // preference, the badge calls out the live serving generation.
    final liveGen = ref.watch(
      cellularGenerationProvider.select((a) => a.value),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.network_cell_rounded,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Network mode',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Force radio onto a specific generation',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (asyncMode.isLoading)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final mode in PreferredNetworkMode.all)
                _ModeChip(
                  mode: mode,
                  active: mode.id == currentId,
                  // Light the LIVE badge on the chip whose label
                  // matches the radio's current serving generation.
                  // Comparison is case-insensitive on the short label
                  // ("4G" / "2G") since `cellularGenerationProvider`
                  // returns lowercase from `_normalizeGen`.
                  live: liveGen != null && liveGen.toUpperCase() == mode.label,
                  onTap: asyncMode.isLoading
                      ? null
                      : () => _apply(context, ref, mode),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _apply(
    BuildContext context,
    WidgetRef ref,
    PreferredNetworkMode mode,
  ) async {
    // forceApply (not set): drive the privileged headless
    // `cmd phone set-allowed-network-types-for-users` so the change
    // actually hits the modem, instead of just writing the stored
    // preference and hoping the BYD ROM reloads. Falls back to the
    // RadioInfo Activity if the ROM refuses the headless call.
    final outcome = await ref
        .read(preferredNetworkModeProvider.notifier)
        .forceApply(mode);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    final (text, warn) = switch (outcome.via) {
      NetworkModeApplied.modem => (
        'Forced ${mode.label} — applied to the modem',
        false,
      ),
      NetworkModeApplied.radioInfo => (
        "Couldn't force ${mode.label} headlessly — opened Phone Info; pick it there",
        true,
      ),
      NetworkModeApplied.channelMissing => (
        'Network control unavailable on this build',
        true,
      ),
      // ROM read back a different value and no force path took
      // (BYD-known quirk) — show truth, not what we asked for.
      NetworkModeApplied.reverted => (
        'ROM reverted${outcome.error != null ? ' — ${outcome.error}' : ''}',
        true,
      ),
    };
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        backgroundColor: warn ? AppColors.warning : null,
        content: Text(text),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.mode,
    required this.active,
    required this.live,
    required this.onTap,
  });
  final PreferredNetworkMode mode;

  /// True when this chip matches the user's *preferred* mode
  /// (`Settings.Global.preferred_network_mode`). Renders as the
  /// accent-tinted "selected" chip — the picker's primary highlight.
  final bool active;

  /// True when the radio is *currently serving* this generation
  /// (independent of preference). Renders a small "LIVE" pill so the
  /// user sees both "what I asked for" (active) and "what I'm
  /// actually on" (live) without leaving the sheet. Both can be true
  /// at once (preferred = live), or only one (preferred Auto, radio
  /// is on 4G → live=true on the 4G chip, active=true on Auto).
  final bool live;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = active ? AppColors.accent : cs.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: active
              ? AppColors.accent.withAlpha(28)
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? AppColors.accent : cs.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (active)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.check_circle,
                  size: 16,
                  color: AppColors.accent,
                ),
              ),
            Text(
              mode.label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
            if (live) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: Colors.green.withValues(alpha: 0.55),
                  ),
                ),
                child: const Text(
                  'LIVE',
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                    color: Colors.green,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Sep extends StatelessWidget {
  const _Sep();
  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant);
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.state,
    required this.onChanged,
    this.rssi,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final NetState state;
  final int? rssi;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final transitioning = state == NetState.transitioning;
    final on = state == NetState.on;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: on ? cs.primary : cs.onSurfaceVariant),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  rssi != null ? '$subtitle · ${rssi}dBm' : subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Switch(value: on, onChanged: transitioning ? null : onChanged),
        ],
      ),
    );
  }
}

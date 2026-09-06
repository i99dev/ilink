import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../kernel/ui/theme/colors.dart';
import '../../../../../platform/network/connectivity_provider.dart';
import '../../../../../kernel/sim/iccid_imsi_generator.dart';
import '../../../../../kernel/sim/sim_identity_override.dart';
import '../../../../../kernel/sim/sim_identity_reader.dart';
import '../../../../../kernel/sim/sim_live_info.dart';

/// "SIM identity" panel rendered under **Settings → Developer**.
///
/// Generates **generic, Luhn-valid Chinese-carrier ICCID + IMSI pairs**
/// for the user to copy into an **external RSIM/programmable-SIM tool**
/// on their phone — these values are NOT for in-car vsim activation.
///
/// **Why this is now informational only (no in-car write):**
///
/// We reverse-engineered the BYD vsim chain (May 2026) and confirmed:
///
///   * The car's vsim activation is gated by a VIN-specific ICCID that
///     BYD's `flow-diagnosis-cn.fangchengbaocloud.com` cloud returns
///     when its `IccidFixer` posts `{brand, vin}`. The ICCID is NOT
///     user-supplied; it's deterministic per-VIN per-brand.
///   * `persist.radio.byd.vsim.iccid` is the prop the modem reads,
///     and it's radio-uid-protected (only `BydWirelessTools`
///     system-uid can write it).
///   * Arbitrary Chinese-carrier ICCIDs (even Luhn-valid) fail
///     Xinsheng's profile-download check; the modem never activates.
///
/// So the in-car "apply override" path can never make the modem
/// honour an arbitrary ICCID. What DOES work for the user is using
/// these generated pairs to provision a **physical RSIM** with their
/// vendor's mobile programmer app — that's an external workflow.
/// This panel exists to produce valid candidate pairs and explain
/// the boundary clearly.
///
/// Persistence: generations + the "active" flag still live in
/// SharedPreferences via [simIdentityOverrideProvider] so the user
/// can pick a value once and re-copy it later. The "active" toggle
/// has no in-car side-effects after the deletion of the
/// BydWirelessTools launcher integration — it's purely a "this is
/// the one I'm currently using externally" bookmark.
class SimIdentityBlock extends ConsumerWidget {
  const SimIdentityBlock({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncOverride = ref.watch(simIdentityOverrideProvider);
    final resolved = ref.watch(resolvedSimIdentityProvider);

    final overrideState = asyncOverride.value ?? SimIdentityOverride.empty;
    final isLoading = asyncOverride.isLoading;

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionDivider(label: 'SIM identity'),
          const SizedBox(height: 12),
          const _ExperimentalNote(),
          const SizedBox(height: 16),
          _CurrentRow(resolved: resolved),
          const SizedBox(height: 16),
          const _DeviceInfoBlock(),
          const SizedBox(height: 16),
          const _Label('Pick carrier'),
          const SizedBox(height: 8),
          _CarrierChipRow(
            disabled: isLoading,
            onPick: (preset) async {
              await ref
                  .read(simIdentityOverrideProvider.notifier)
                  .generateAndApply(preset);
            },
          ),
          if (overrideState.current != null) ...[
            const SizedBox(height: 16),
            _CurrentGeneratedCard(
              entry: overrideState.current!,
              active: overrideState.active,
              onApply: overrideState.active
                  ? null
                  : () async => ref
                        .read(simIdentityOverrideProvider.notifier)
                        .applyFromHistory(overrideState.current!),
              onClear: overrideState.active
                  ? () async => ref
                        .read(simIdentityOverrideProvider.notifier)
                        .deactivate()
                  : null,
            ),
            const SizedBox(height: 12),
            const _ExternalUseInfoCard(),
          ],
          if (overrideState.history.length > 1) ...[
            const SizedBox(height: 20),
            const _Label('History'),
            const SizedBox(height: 8),
            // First entry is the same as `current`, skip it to avoid
            // duplicating the card above.
            ...overrideState.history
                .skip(1)
                .map(
                  (entry) => _HistoryRow(
                    entry: entry,
                    onReapply: () async => ref
                        .read(simIdentityOverrideProvider.notifier)
                        .applyFromHistory(entry),
                  ),
                ),
          ],
          if (overrideState.history.isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: () async =>
                    ref.read(simIdentityOverrideProvider.notifier).reset(),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Reset history'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionDivider extends StatelessWidget {
  const _SectionDivider({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(child: Divider(color: cs.outlineVariant)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
              letterSpacing: 0.4,
            ),
          ),
        ),
        Expanded(child: Divider(color: cs.outlineVariant)),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: cs.onSurfaceVariant,
        letterSpacing: 0.4,
      ),
    );
  }
}

class _ExperimentalNote extends StatelessWidget {
  const _ExperimentalNote();
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.warning.withAlpha(28),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.warning.withAlpha(80)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.science_outlined,
            size: 18,
            color: AppColors.warning,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Cosmetic only — overrides what apps show, not what the '
              'modem uses. Real SIM ICCID stays unchanged.',
              style: TextStyle(fontSize: 12, color: cs.onSurface, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _CurrentRow extends StatelessWidget {
  const _CurrentRow({required this.resolved});
  final ResolvedSimIdentity resolved;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final shown = resolved.iccid.isEmpty ? '—' : resolved.iccid;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Current ICCID',
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurfaceVariant,
                  letterSpacing: 0.4,
                ),
              ),
              const Spacer(),
              _StatusBadge(active: resolved.overrideActive),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            shown,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
          if (resolved.overrideActive && resolved.realIccid.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Real prop: ${resolved.realIccid}',
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? AppColors.accent
        : Theme.of(context).colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(36),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text(
        active ? 'OVERRIDDEN' : 'REAL',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: color,
        ),
      ),
    );
  }
}

class _CarrierChipRow extends StatelessWidget {
  const _CarrierChipRow({required this.disabled, required this.onPick});
  final bool disabled;
  final void Function(ChineseCarrierPreset) onPick;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final preset in ChineseCarrierPreset.all)
          _CarrierChip(
            preset: preset,
            onTap: disabled ? null : () => onPick(preset),
          ),
      ],
    );
  }
}

class _CarrierChip extends StatelessWidget {
  const _CarrierChip({required this.preset, required this.onTap});
  final ChineseCarrierPreset preset;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sim_card_outlined, size: 16),
            const SizedBox(width: 8),
            Text(
              preset.label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrentGeneratedCard extends StatelessWidget {
  const _CurrentGeneratedCard({
    required this.entry,
    required this.active,
    required this.onApply,
    required this.onClear,
  });
  final GeneratedSimIdentity entry;
  final bool active;
  final VoidCallback? onApply;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: active
            ? AppColors.accent.withAlpha(20)
            : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: active ? AppColors.accent : cs.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.accent.withAlpha(36),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  entry.carrier.label,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: AppColors.accent,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Generated pair',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _CopyableValueRow(label: 'ICCID', value: entry.iccid),
          const SizedBox(height: 8),
          _CopyableValueRow(label: 'IMSI', value: entry.imsi),
          const SizedBox(height: 14),
          Row(
            children: [
              if (onApply != null)
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onApply,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Apply override'),
                  ),
                ),
              if (onClear != null)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onClear,
                    icon: const Icon(Icons.cancel_outlined, size: 18),
                    label: const Text('Clear override'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CopyableValueRow extends StatelessWidget {
  const _CopyableValueRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
              letterSpacing: 0.4,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
        ),
        IconButton(
          tooltip: 'Copy $label',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: value));
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
                content: Text('$label copied'),
              ),
            );
          },
          icon: const Icon(Icons.copy, size: 18),
        ),
      ],
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, required this.onReapply});
  final GeneratedSimIdentity entry;
  final VoidCallback onReapply;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: onReapply,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  entry.carrier.label,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  entry.iccid,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.replay, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// Live device-side network info read straight from the modem via
/// the shell bridge. Rendered between the override-aware Current
/// ICCID row and the carrier chips so the user can compare what the
/// modem reports vs what the spoof published, without leaving the
/// USIM sheet to open the BYD Network Information dialog.
///
/// Polled every 10s by [simLiveInfoProvider]; a manual refresh
/// invalidates the stream provider to force an immediate re-read.
class _DeviceInfoBlock extends ConsumerWidget {
  const _DeviceInfoBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final asyncInfo = ref.watch(simLiveInfoProvider);
    final cellGen = ref.watch(
      cellularGenerationProvider.select((a) => a.value),
    );
    final overrideAsync = ref.watch(simIdentityOverrideProvider);
    final info = asyncInfo.value ?? SimLiveInfo.empty;
    final loading = asyncInfo.isLoading && !asyncInfo.hasValue;
    final override = overrideAsync.value ?? SimIdentityOverride.empty;

    // Fields the override CAN spoof (because the generator produces them):
    //   - IMSI: override.current.imsi
    //   - Operator: derived from the carrier preset's display name + MCCMNC
    // Fields the override CANNOT spoof (hardware truth, no derivation):
    //   - IMEI (baked into modem chip, not the SIM)
    //   - SIM state (physical slot reality)
    //   - Network type (depends on the actual radio link)
    final spoof = override.active && override.current != null
        ? override.current!
        : null;
    final imsiValue = spoof?.imsi ?? info.imsi;
    final operatorValue = spoof != null
        ? '${spoof.carrier.displayName} (${spoof.carrier.imsiMccMnc})'
        : _realOperatorDisplay(info);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Device info',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant,
                  letterSpacing: 0.4,
                ),
              ),
              const Spacer(),
              _SimStateBadge(state: info.simState),
              const SizedBox(width: 8),
              InkWell(
                onTap: () => ref.invalidate(simLiveInfoProvider),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: loading
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: cs.onSurfaceVariant,
                          ),
                        )
                      : Icon(
                          Icons.refresh,
                          size: 18,
                          color: cs.onSurfaceVariant,
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _InfoRow(label: 'IMSI', value: imsiValue, spoofed: spoof != null),
          const SizedBox(height: 6),
          _InfoRow(label: 'IMEI', value: info.imei),
          const SizedBox(height: 6),
          _InfoRow(
            label: 'Operator',
            value: operatorValue,
            spoofed: spoof != null,
          ),
          const SizedBox(height: 6),
          _InfoRow(
            label: 'Network',
            value: cellGen == null ? '—' : cellGen.toUpperCase(),
          ),
        ],
      ),
    );
  }

  /// Combines [SimLiveInfo.operatorName] and [SimLiveInfo.operatorNumeric]
  /// into "etisalat (42402)" — falls back to whichever half exists,
  /// then to "—" when both are empty. Used only when no spoof is
  /// active; when active, the operator value is derived from the
  /// carrier preset instead.
  String _realOperatorDisplay(SimLiveInfo info) {
    final name = info.operatorName;
    final numeric = info.operatorNumeric;
    if (name.isNotEmpty && numeric.isNotEmpty) return '$name ($numeric)';
    if (name.isNotEmpty) return name;
    if (numeric.isNotEmpty) return numeric;
    return '—';
  }
}

class _SimStateBadge extends StatelessWidget {
  const _SimStateBadge({required this.state});
  final String state;

  @override
  Widget build(BuildContext context) {
    final upper = state.toUpperCase();
    // Three-bucket palette: green for "card is in and usable", amber
    // for "in slot but blocked" (PIN/PUK), red for absent. Anything
    // else (UNKNOWN, NOT_READY) gets the neutral outline color.
    final cs = Theme.of(context).colorScheme;
    final color = switch (upper) {
      'READY' || 'LOADED' => AppColors.accent,
      'PIN_REQUIRED' || 'PUK_REQUIRED' || 'NETWORK_LOCKED' => AppColors.warning,
      'ABSENT' => const Color(0xFFD93939),
      _ => cs.outline,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(36),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text(
        upper,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: color,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.spoofed = false,
  });
  final String label;
  final String value;

  /// True when [value] came from the SIM identity override rather
  /// than the modem. Tints the text accent-green so the user can see
  /// at a glance which fields are real vs spoofed; pairs with the
  /// "OVERRIDDEN" badge on the Current ICCID row above.
  final bool spoofed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final valueEmpty = value.isEmpty;
    final valueColor = valueEmpty
        ? cs.onSurfaceVariant
        : (spoofed ? AppColors.accent : cs.onSurface);
    return Row(
      children: [
        SizedBox(
          width: 70,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
              letterSpacing: 0.4,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            valueEmpty ? '—' : value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
              color: valueColor,
            ),
          ),
        ),
        if (spoofed && !valueEmpty) ...[
          const SizedBox(width: 6),
          const Tooltip(
            message: 'Spoofed by SIM identity override',
            child: Icon(Icons.auto_fix_high, size: 14, color: AppColors.accent),
          ),
        ],
      ],
    );
  }
}

/// Info card explaining that the generated ICCID + IMSI pair is for
/// **external** use — i.e. programming a physical RSIM via a phone
/// app — not in-car vsim activation.
///
/// We deleted the prior "Apply via BYD Vsim Editor" CTA after we
/// confirmed the BYD chain rejects arbitrary ICCIDs (it requires the
/// VIN-specific ICCID returned by `flow-diagnosis-cn.fangchengbaocloud.com`).
/// Leaving a button that demonstrably never activates the modem
/// would mislead users into thinking it might. The replacement is
/// honest: a one-line "this is for your phone-based RSIM tool" hint
/// next to the Copy buttons on the generated card above.
class _ExternalUseInfoCard extends StatelessWidget {
  const _ExternalUseInfoCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.smartphone_outlined, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'For external (phone-side) use',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Copy the ICCID + IMSI above into your RSIM / programmable-SIM '
                  "app on your phone — that's where they get written to the "
                  "card. The car's vsim activation is separate and requires "
                  "a VIN-specific ICCID from BYD's cloud, so these generic "
                  'pairs will not activate the modem if pasted in-car.',
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

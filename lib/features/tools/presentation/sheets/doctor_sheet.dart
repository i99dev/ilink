import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/i18n/generated/app_localizations.dart';
import '../../../../kernel/ui/theme/colors.dart';
import '../../../../sdk/car/providers.dart' show daemonReadyProvider;
import '../../domain/quick_fix_action.dart';
import '../../registry/quick_fix_registry.dart';
import '../../state/quick_fix_controller.dart';

/// Bottom sheet shown when the Doctor circle is tapped. One tappable row
/// per quick-fix action (close other apps / clear cluster / wake car
/// service), each with a visible "why" line + a long-press tooltip and a
/// busy/result indicator. Dumb renderer over [kQuickFixActions] +
/// [quickFixControllerProvider] — adding an action never touches this file.
class DoctorSheet extends ConsumerWidget {
  const DoctorSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final runStates = ref.watch(quickFixControllerProvider);

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
              Text(
                s.toolsDoctorTitle,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                s.doctorSubtitle,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final action in kQuickFixActions)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _QuickFixRow(
                            action: action,
                            runState:
                                runStates[action.id] ?? QuickFixRunState.idle,
                          ),
                        ),
                    ],
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

class _QuickFixRow extends ConsumerWidget {
  const _QuickFixRow({required this.action, required this.runState});

  final QuickFixAction action;
  final QuickFixRunState runState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final running = runState.status == QuickFixStatus.running;
    final accent = switch (runState.status) {
      QuickFixStatus.ok => AppColors.accent,
      QuickFixStatus.failed => AppColors.error,
      QuickFixStatus.running => AppColors.secondary,
      QuickFixStatus.idle => cs.onSurfaceVariant,
    };
    final borderColor = runState.status == QuickFixStatus.idle
        ? cs.outlineVariant
        : accent.withValues(alpha: 0.7);
    // The Wake-car-service row doubles as a live daemon indicator: its
    // leading icon goes green whenever the daemon is currently up,
    // independent of the last run result, so a glance confirms the
    // service is alive (the "did waking it actually take?" answer).
    final daemonUp =
        action.id == kWakeDaemonActionId &&
        (ref.watch(daemonReadyProvider).value ?? false);
    final iconColor = daemonUp ? AppColors.accent : accent;
    final why = _why(s, action);
    final result = _result(s, action, runState);

    // Tooltip carries the same "why" for long-press discovery on the
    // touchscreen (the subtitle already shows it inline).
    return Tooltip(
      message: why,
      child: InkWell(
        onTap: running
            ? null
            : () => ref.read(quickFixControllerProvider.notifier).run(action),
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconColor.withAlpha(28),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(action.icon, color: iconColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _label(s, action),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      result ?? why,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: runState.status == QuickFixStatus.idle
                            ? cs.onSurfaceVariant
                            : accent,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _Trailing(status: runState.status, accent: accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _Trailing extends StatelessWidget {
  const _Trailing({required this.status, required this.accent});

  final QuickFixStatus status;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      QuickFixStatus.running => SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.4, color: accent),
      ),
      QuickFixStatus.ok => Icon(Icons.check_circle_rounded, color: accent),
      QuickFixStatus.failed => Icon(Icons.error_rounded, color: accent),
      QuickFixStatus.idle => Icon(
        Icons.play_circle_outline_rounded,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    };
  }
}

String _label(S s, QuickFixAction a) => switch (a.labelKey) {
  'doctorCloseAppsLabel' => s.doctorCloseAppsLabel,
  'doctorClearClusterLabel' => s.doctorClearClusterLabel,
  'doctorWakeDaemonLabel' => s.doctorWakeDaemonLabel,
  _ => a.labelKey,
};

String _why(S s, QuickFixAction a) => switch (a.whyKey) {
  'doctorCloseAppsWhy' => s.doctorCloseAppsWhy,
  'doctorClearClusterWhy' => s.doctorClearClusterWhy,
  'doctorWakeDaemonWhy' => s.doctorWakeDaemonWhy,
  _ => a.whyKey,
};

String? _result(S s, QuickFixAction a, QuickFixRunState st) =>
    switch (st.status) {
      QuickFixStatus.running => s.doctorRunning,
      QuickFixStatus.ok =>
        a.id == kCloseAppsActionId
            ? s.doctorCloseAppsResult(st.count ?? 0)
            : s.doctorActionDone,
      QuickFixStatus.failed => s.doctorActionFailed,
      QuickFixStatus.idle => null,
    };

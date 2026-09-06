library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ilink/features/workflow/domain/workflow_summary.dart';
import '../../../kernel/i18n/generated/app_localizations.dart';
import '../../../kernel/ui/theme/colors.dart';
import '../data/workflow_providers.dart';
import '../bridge/workflow_bridge_service.dart';

/// Workflows the user can control, sorted active-first then by name.
List<WorkflowSummary> _sorted(List<WorkflowSummary> workflows) {
  final list = [...workflows];
  list.sort((a, b) {
    if (a.enabled != b.enabled) return a.enabled ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return list;
}

/// Bottom sheet shown when the "Automations" tool circle is tapped. View
/// + on/off only. Follows the Doctor/Network sheet idiom (SafeArea →
/// Padding → ConstrainedBox → Column; the modal supplies surface + drag
/// handle).
class WorkflowControlSheet extends ConsumerStatefulWidget {
  const WorkflowControlSheet({super.key});

  @override
  ConsumerState<WorkflowControlSheet> createState() =>
      _WorkflowControlSheetState();
}

class _WorkflowControlSheetState extends ConsumerState<WorkflowControlSheet> {
  // id → desired state while the round-trip is in flight (optimistic UI +
  // double-tap guard). Cleared when the refreshed digest confirms it.
  final Map<String, bool> _pending = {};

  Future<void> _toggle(WorkflowSummary w, bool next) async {
    setState(() => _pending[w.id] = next);
    final res = await ref.read(workflowBridgeServiceProvider).setEnabled({
      'id': w.id,
      'enabled': next,
    });
    if (!mounted) return;
    setState(() => _pending.remove(w.id));
    if (res['error'] != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            'Couldn’t turn ${next ? 'on' : 'off'} “${w.name}”. Try again.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final workflows = _sorted(
      ref.watch(localWorkflowDigestProvider).value ?? const [],
    );
    final activeCount = workflows.where((w) => w.enabled).length;

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
              Row(
                children: [
                  const Icon(
                    Icons.bolt_rounded,
                    color: AppColors.accent,
                    size: 24,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    s.toolsWorkflowLabel,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                workflows.isEmpty
                    ? 'Turn your automations on or off'
                    : '$activeCount of ${workflows.length} running',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              if (workflows.isEmpty)
                _empty(cs)
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: workflows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _row(workflows[i], cs),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(WorkflowSummary w, ColorScheme cs) {
    final value = _pending[w.id] ?? w.enabled;
    final busy = _pending.containsKey(w.id);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  w.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  value ? 'Running' : 'Off',
                  style: TextStyle(
                    fontSize: 12,
                    color: value ? AppColors.accent : cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Switch(
            value: value,
            onChanged: busy ? null : (next) => _toggle(w, next),
          ),
        ],
      ),
    );
  }

  Widget _empty(ColorScheme cs) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.bolt_outlined, size: 40, color: cs.onSurfaceVariant),
        const SizedBox(height: 12),
        Text(
          'No automations yet',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Build one in the Workflow Canvas mini-app, then turn it on here.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
        ),
      ],
    ),
  );
}

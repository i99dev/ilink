import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/i18n/generated/app_localizations.dart';
import '../../../kernel/registry/action_def.dart';
import '../../../kernel/ui/confirm_sheet.dart';
import '../domain/app_action.dart';
import '../domain/app_meta.dart';
import '../domain/app_target.dart';
import '../registry/app_actions_registry.dart';
import '../state/app_action_controller.dart';
import '../state/app_meta_provider.dart';
import 'widgets/action_circle.dart';

/// Public entry point. Single sheet for both native apps and
/// mini-apps. Open from any tile's long-press handler:
///
/// ```dart
/// await showAppActionsSheet(
///   context: ctx,
///   target: NativeAppTarget(packageName: 'com.foo', label: 'Foo'),
/// );
/// ```
Future<void> showAppActionsSheet({
  required BuildContext context,
  required AppTarget target,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetCtx) => _AppActionsSheet(target: target),
  );
}

class _AppActionsSheet extends ConsumerWidget {
  const _AppActionsSheet({required this.target});
  final AppTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final cs = Theme.of(context).colorScheme;
    final metaAsync = ref.watch(appMetaForTargetProvider(target));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _Header(target: target, meta: metaAsync.value),
                const SizedBox(height: 16),
                // "Open on …" + display-target chips removed per
                // operator — the manage-app sheet is for app
                // ACTIONS only; display targeting belongs to the
                // drag-and-drop picker (single source of truth for
                // "where does this app go").
                Text(
                  s.appActionsSheetTitle,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                metaAsync.when(
                  loading: _SkeletonRow.new,
                  error: (e, _) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Text('$e', style: TextStyle(color: cs.error)),
                  ),
                  data: (meta) => _ActionsRow(target: target, meta: meta),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.target, required this.meta});
  final AppTarget target;
  final AppMeta? meta;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final subtitle = _buildSubtitle();
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                target.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              if (subtitle.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _buildSubtitle() {
    final parts = <String>[];
    final t = target;
    if (t is NativeAppTarget) parts.add(t.packageName);
    if (t is MiniAppTarget) parts.add(t.appId);
    final m = meta;
    if (m != null) {
      if (m.versionName != null) parts.add('v${m.versionName}');
      if (m.sizeBytes != null) {
        final mb = (m.sizeBytes! / (1024 * 1024)).toStringAsFixed(0);
        parts.add('$mb MB');
      }
    }
    return parts.join(' · ');
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 96,
      child: Row(
        children: List.generate(7, (_) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: CircleAvatar(
              radius: 32,
              backgroundColor: cs.surfaceContainerHigh,
            ),
          );
        }),
      ),
    );
  }
}

class _ActionsRow extends ConsumerStatefulWidget {
  const _ActionsRow({required this.target, required this.meta});
  final AppTarget target;
  final AppMeta meta;

  @override
  ConsumerState<_ActionsRow> createState() => _ActionsRowState();
}

class _ActionsRowState extends ConsumerState<_ActionsRow> {
  String? _busyId;

  Future<void> _onTap(ActionDef<AppTarget, AppMeta> def) async {
    final s = S.of(context);
    if (def.severity != ActionSeverity.safe) {
      final body = _resolveConfirmBody(s, def.confirmKey);
      final tokenHint = _resolveTokenHint(s, def.id);
      final ok = await showConfirmSheet(
        context: context,
        title: _resolveConfirmTitle(s, def.id, widget.target.label),
        body: body,
        severity: def.severity,
        confirmLabel: s.appActionConfirm,
        cancelLabel: s.appActionCancel,
        typedToken: def.typedToken,
        typedTokenHint: tokenHint,
      );
      if (ok != true) return;
    }
    setState(() => _busyId = def.id);
    final outcome = await ref
        .read(appActionControllerProvider.notifier)
        .run(kind: kindFromId(def.id), target: widget.target);
    if (!mounted) return;
    setState(() => _busyId = null);
    final ok = outcome == AppActionOutcome.ok;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(ok ? s.appActionToastOk : s.appActionToastFailed),
        duration: const Duration(milliseconds: 1600),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final def in kAppActionsRegistry) ...[
            ActionCircle(
              def: def,
              label: _resolveActionLabel(s, def.labelKey),
              meta: widget.meta,
              busy: _busyId == def.id,
              onTap: () => _onTap(def),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

/// Resolves the action label key. Indirection keeps the registry
/// runtime-string-free; the validation test asserts every key resolves.
String _resolveActionLabel(S s, String key) => switch (key) {
  'appActionEnable' => s.appActionEnable,
  'appActionDisable' => s.appActionDisable,
  'appActionUninstall' => s.appActionUninstall,
  'appActionTransfer' => s.appActionTransfer,
  'appActionForceStop' => s.appActionForceStop,
  'appActionClearData' => s.appActionClearData,
  'appActionWhitelist' => s.appActionWhitelist,
  _ => key,
};

String _resolveConfirmTitle(S s, String id, String label) => switch (id) {
  'disable' => s.appActionDisableConfirmTitle(label),
  'uninstall' => s.appActionUninstallConfirmTitle(label),
  'clearData' => s.appActionClearDataConfirmTitle(label),
  _ => label,
};

String _resolveConfirmBody(S s, String? key) => switch (key) {
  'appActionDisableConfirmBody' => s.appActionDisableConfirmBody,
  'appActionUninstallConfirmBody' => s.appActionUninstallConfirmBody,
  'appActionClearDataConfirmBody' => s.appActionClearDataConfirmBody,
  _ => '',
};

String? _resolveTokenHint(S s, String id) => switch (id) {
  'uninstall' => s.appActionUninstallTokenHint,
  'clearData' => s.appActionClearDataTokenHint,
  _ => null,
};

import 'package:flutter/material.dart';

import '../../../../kernel/registry/action_def.dart';
import '../../domain/app_meta.dart';
import '../../domain/app_target.dart';

/// One circular tile in the actions row of [AppActionsSheet]. Wrapped
/// in a [RepaintBoundary] so a meta tick on action A doesn't repaint
/// action B.
class ActionCircle extends StatelessWidget {
  const ActionCircle({
    super.key,
    required this.def,
    required this.label,
    required this.meta,
    required this.onTap,
    required this.busy,
  });

  final ActionDef<AppTarget, AppMeta> def;
  final String label;
  final AppMeta meta;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final eligible = def.eligible(meta);
    final destructive = def.severity != ActionSeverity.safe;
    final fg = !eligible
        ? cs.outline
        : destructive
        ? cs.error
        : cs.onSurface;
    return RepaintBoundary(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: eligible && !busy ? onTap : null,
          child: SizedBox(
            width: 84,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.surfaceContainerHigh,
                    border: Border.all(
                      color: !eligible
                          ? cs.outlineVariant.withValues(alpha: 0.4)
                          : destructive
                          ? cs.error.withValues(alpha: 0.6)
                          : cs.outlineVariant,
                      width: 1.4,
                    ),
                  ),
                  child: Center(
                    child: busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          )
                        : IconTheme.merge(
                            data: IconThemeData(color: fg, size: 26),
                            child: def.iconBuilder(context, meta),
                          ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

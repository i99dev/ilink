import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../domain/tool.dart';
import '../../registry/tools_registry.dart';

/// One circular tile on the Tools strip. Wrapped in a [RepaintBoundary]
/// so a connectivity tick on tool A doesn't repaint tool B.
class ToolCircle extends ConsumerWidget {
  const ToolCircle({super.key, required this.tool});

  final Tool tool;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final ring = tool.ringStatusFor(ref);
    final ringColor = switch (ring) {
      ToolStatusRing.online => AppColors.accent,
      ToolStatusRing.transitioning => AppColors.warning,
      ToolStatusRing.offline => cs.outlineVariant,
      ToolStatusRing.unknown => cs.outlineVariant.withValues(alpha: 0.4),
    };

    return RepaintBoundary(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _open(context),
          child: Container(
            width: 72,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.surfaceContainerHigh,
                    border: Border.all(color: ringColor, width: 2),
                    boxShadow: ring == ToolStatusRing.online
                        ? [
                            BoxShadow(
                              color: ringColor.withAlpha(60),
                              blurRadius: 10,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: Center(child: tool.iconBuilder(context)),
                ),
                const SizedBox(height: 6),
                Text(
                  resolveToolLabel(context, tool.labelKey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      // Lazy: builder defers widget construction to tap time.
      builder: (sheetCtx) => tool.sheetBuilder(sheetCtx),
    );
  }
}

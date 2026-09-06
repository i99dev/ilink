import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../registry/tools_registry.dart';
import 'widgets/tool_circle.dart';

/// Replaces HeroPanel as the top slot of the right pane on the home
/// screen. Renders a horizontally-scrolling strip of circular tool
/// shortcuts; iterates [kToolsRegistry] so adding a tool is a
/// registry-only change.
class ToolsPanel extends ConsumerWidget {
  const ToolsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
      ),
      // Title row dropped — at 20% the strip can't afford a header
      // line, and the circles' own labels already name each tool.
      // Horizontal padding only; vertical spacing comes from the
      // ToolCircle's own column.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (final tool in kToolsRegistry) ToolCircle(tool: tool),
            ],
          ),
        ),
      ),
    );
  }
}

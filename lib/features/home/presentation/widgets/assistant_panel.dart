import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_drag_controller.dart';
import '../../state/displays_picker_active_provider.dart';
import '../../state/running_apps_provider.dart';
import 'display_drop_picker.dart';
import 'voice_shortcuts_tile.dart';

/// Left pane of the home screen. Two views, one toggle:
///
///   * **Voice shortcuts** — default. The "TRY SAYING" chip card.
///     Tapping the dock mic or a chip kicks off a voice session.
///   * **Display widget** — the [DisplayDropPicker] with running-app
///     chips embedded in each display card. Long-press a chip to
///     drag it onto another card and the task moves to that display
///     (the launch resolver picks Resume / Migrate server-side).
///
/// The toggle is the icon button in the top-right of the panel; its
/// glyph + label flip with the active view. While the user is
/// long-press-dragging an app from the Apps tab in the right pane,
/// the picker is force-shown regardless of toggle state — that's
/// how the user's "long-press → drop on display" gesture stays one
/// fluid motion. Total chip count surfaces in the toggle's label so
/// the user has a glanceable signal of "how many things are
/// running" without entering the displays view.
class AssistantPanel extends ConsumerWidget {
  const AssistantPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dragging = ref.watch(
      appDragControllerProvider.select((d) => d != null),
    );
    final userToggled = ref.watch(displaysPickerActiveProvider);
    final showPicker = dragging || userToggled;
    // Use `.value` (not `maybeWhen(data:, orElse:)`) so the badge
    // doesn't flicker to 0 every 2 s. Each refresh tick transitions
    // the FutureProvider through AsyncLoading<T> (with the previous
    // value carried) before settling back to AsyncData. `maybeWhen`
    // only matches AsyncData, so loading falls through to `orElse`
    // and returns 0 mid-poll. `.value` collapses AsyncData and
    // AsyncLoading-with-previous into the same `T?`, so the count
    // stays stable across polls and only changes when the actual
    // running-task count changes.
    final runningCount = ref.watch(
      runningAppsProvider.select(
        (a) => a.value?.values.fold<int>(0, (s, l) => s + l.length) ?? 0,
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ToggleHeader(
            showingDisplays: showPicker,
            // Disable the toggle while a drag is active — the picker
            // is force-shown until the drop completes; a mid-drag
            // tap that flipped state would leave the user with no
            // valid drop target.
            disabled: dragging,
            runningCount: runningCount,
            onTap: () =>
                ref.read(displaysPickerActiveProvider.notifier).toggle(),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: showPicker
                  ? const DisplayDropPicker(key: ValueKey('displays'))
                  : const VoiceShortcutsTile(key: ValueKey('voice')),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToggleHeader extends StatelessWidget {
  const _ToggleHeader({
    required this.showingDisplays,
    required this.disabled,
    required this.runningCount,
    required this.onTap,
  });

  final bool showingDisplays;
  final bool disabled;
  final int runningCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: showingDisplays
                ? cs.primaryContainer.withValues(alpha: 0.6)
                : cs.surfaceContainerHigh.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: showingDisplays
                  ? cs.primary.withValues(alpha: 0.6)
                  : cs.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            children: [
              Icon(
                showingDisplays
                    ? Icons.mic_none_outlined
                    : Icons.layers_outlined,
                size: 20,
                color: showingDisplays ? cs.onPrimaryContainer : cs.onSurface,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  showingDisplays ? 'BACK TO ASSISTANT' : 'SHOW DISPLAYS',
                  style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 1.6,
                    fontWeight: FontWeight.w700,
                    color: showingDisplays
                        ? cs.onPrimaryContainer
                        : cs.onSurface,
                  ),
                ),
              ),
              if (runningCount > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$runningCount',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: cs.onPrimary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

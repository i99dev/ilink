import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/i18n/generated/app_localizations.dart';
import '../state/mini_app_sections.dart';
import '../state/mini_app_view_mode.dart';
import 'import_local_mini_app.dart';

/// Mini Apps surface.
///
/// Embedded as a top-level tab in the shell's [PageView] (see
/// `DashScreen.miniApps` + `visibleScreensProvider` in `dash_shell.dart`),
/// so this widget must **not** wrap itself in a Scaffold — the shell
/// already owns the TopStatusBar and the DashPillDock.
///
/// Layout: a header row with [TabBar] + view-mode toggle, then a
/// [TabBarView] for the visible sections.
///
/// **Sections come from [visibleMiniAppSectionsProvider]**, not a
/// hard-coded list. Each [MiniAppSection] declares its own visibility
/// predicate; the developer/flight-test tab is hidden until
/// Settings → Developer → "Flight test mode" is on, and adding a
/// new section is a one-liner in `mini_app_sections.dart`. This
/// screen's only job is to wire the visible set into a tab
/// controller and rebuild it when the count changes.
///
/// **TabController rebuild**: `length` is final on [TabController]
/// so we dispose + re-create when the visible count flips. Selection
/// is preserved by `id` — if the active section is still visible it
/// stays selected; if it disappeared (e.g. flight-test toggled off
/// while parked on it), focus clamps to the nearest valid index.
class MiniAppsScreen extends ConsumerStatefulWidget {
  const MiniAppsScreen({super.key});

  @override
  ConsumerState<MiniAppsScreen> createState() => _MiniAppsScreenState();
}

class _MiniAppsScreenState extends ConsumerState<MiniAppsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _controller;
  late List<String> _lastSectionIds;

  @override
  void initState() {
    super.initState();
    final sections = ref.read(visibleMiniAppSectionsProvider);
    _lastSectionIds = sections.map((s) => s.id).toList(growable: false);
    _controller = TabController(length: sections.length, vsync: this);
  }

  /// Recreate the [TabController] when the visible-section list
  /// changes — `length` is final on TabController. Preserves the
  /// user's selection by section id (fall back to nearest valid
  /// index when the active section was removed).
  void _rebuildControllerForSections(List<MiniAppSection> next) {
    final priorActiveId = _lastSectionIds.length > _controller.index
        ? _lastSectionIds[_controller.index]
        : null;
    final nextIds = next.map((s) => s.id).toList(growable: false);
    var initialIndex = priorActiveId != null
        ? nextIds.indexOf(priorActiveId)
        : -1;
    if (initialIndex < 0) {
      initialIndex = _controller.index.clamp(
        0,
        nextIds.isEmpty ? 0 : nextIds.length - 1,
      );
    }

    _controller.dispose();
    _controller = TabController(
      length: nextIds.length,
      vsync: this,
      initialIndex: initialIndex,
    );
    _lastSectionIds = nextIds;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final theme = Theme.of(context);
    final viewMode = ref.watch(miniAppViewModeProvider);
    final sections = ref.watch(visibleMiniAppSectionsProvider);

    // React to changes in the VISIBLE SET (length OR composition,
    // since predicates can change ordering). Comparison by id so a
    // section's content rebuild doesn't trigger a controller swap.
    final currentIds = sections.map((s) => s.id).toList(growable: false);
    if (!_listEquals(currentIds, _lastSectionIds)) {
      // schedule a post-frame rebuild — calling setState here is fine
      // because we're in build, but we also can't dispose the
      // controller mid-render. Defer.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_listEquals(
          ref.read(visibleMiniAppSectionsProvider).map((s) => s.id).toList(),
          _lastSectionIds,
        )) {
          setState(() {
            _rebuildControllerForSections(
              ref.read(visibleMiniAppSectionsProvider),
            );
          });
        }
      });
    }

    return Column(
      children: [
        Material(
          color: theme.colorScheme.surface,
          child: Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: _controller,
                  tabs: [for (final s in sections) Tab(text: s.labelOf(t))],
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Import mini-app bundle',
                icon: const Icon(Icons.file_open_outlined),
                onPressed: () => importLocalMiniApp(context, ref),
              ),
              _ViewModeToggle(mode: viewMode),
              const SizedBox(width: 12),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _controller,
            children: [for (final s in sections) s.build()],
          ),
        ),
      ],
    );
  }
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Two-icon segmented control for grid vs list. Sticky preference —
/// [MiniAppViewModeController] persists to SharedPreferences so the
/// next launch opens with the user's last choice.
class _ViewModeToggle extends ConsumerWidget {
  const _ViewModeToggle({required this.mode});

  final MiniAppViewMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    Widget segment(MiniAppViewMode target, IconData icon, String tooltip) {
      final selected = mode == target;
      return Tooltip(
        message: tooltip,
        child: Material(
          color: selected ? cs.primary.withAlpha(30) : Colors.transparent,
          child: InkWell(
            onTap: () => ref.read(miniAppViewModeProvider.notifier).set(target),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Icon(
                icon,
                size: 18,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          segment(MiniAppViewMode.grid, Icons.grid_view_rounded, 'Grid view'),
          segment(MiniAppViewMode.list, Icons.view_list_rounded, 'List view'),
        ],
      ),
    );
  }
}

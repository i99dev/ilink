import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/i18n/generated/app_localizations.dart';
import 'favorite_mini_apps_strip.dart';
import 'installed_apps_strip.dart';

/// Tabbed lower-pane panel hosting Apps (native Android packages) and
/// Miniapps (iLINK favourites). Slim header so the 75 % flex slot
/// stays dominated by tile content, not chrome.
class HomeAppsTabsPanel extends ConsumerStatefulWidget {
  const HomeAppsTabsPanel({super.key});

  @override
  ConsumerState<HomeAppsTabsPanel> createState() => _HomeAppsTabsPanelState();
}

class _HomeAppsTabsPanelState extends ConsumerState<HomeAppsTabsPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: SizedBox(
            height: 32,
            child: TabBar(
              controller: _controller,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelColor: cs.onSurface,
              unselectedLabelColor: cs.onSurfaceVariant,
              labelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
              unselectedLabelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 1.2,
              ),
              indicatorSize: TabBarIndicatorSize.label,
              indicatorWeight: 2,
              dividerColor: Colors.transparent,
              padding: EdgeInsets.zero,
              labelPadding: const EdgeInsets.symmetric(horizontal: 12),
              tabs: [
                Tab(text: t.homeTabAppsLabel.toUpperCase()),
                Tab(text: t.homeTabMiniappsLabel.toUpperCase()),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: TabBarView(
            controller: _controller,
            children: const [
              InstalledAppsStrip(showTitle: false),
              FavoriteMiniAppsStrip(),
            ],
          ),
        ),
      ],
    );
  }
}

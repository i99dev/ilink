import 'package:flutter/material.dart';

import '../../../tools/index.dart';
import 'home_apps_tabs_panel.dart';

/// Right-hand pane of the home screen: Tools strip on top, tabbed
/// Apps / Mini-apps grid below.
///
/// Layout flex 20 / 80 — Tools strip is a single row of compact
/// circles; the 20% slice fits a 56dp circle + label without
/// overflow while leaving the bulk of the screen for the apps grid.
///
/// `HeroPanel` (car status hero) is intentionally removed; the Tools
/// circle is what users tap to open per-tool modes (network, audio,
/// climate, …). Vehicle status surfaces in the assistant panel and
/// inside specific mini-apps that need it — not as a permanent strip.
class CarStatusPanel extends StatelessWidget {
  const CarStatusPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(8, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 20, child: ToolsPanel()),
          SizedBox(height: 12),
          Expanded(flex: 80, child: HomeAppsTabsPanel()),
        ],
      ),
    );
  }
}

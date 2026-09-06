/// Top-level entry for the dashboard surface. Renders the legacy
/// assistant + apps two-pane layout.
///
/// History: pre-May 2026 this screen hosted a `PageView` whose first
/// page was a 3D car centerpiece. That page was hidden, then the whole
/// 3D subtree (centerpiece, `CarPage`, playground editor, the GLB
/// assets, and the `flutter_3d_controller` runtime — ~12 MB of APK)
/// was deleted in June 2026 since nothing reachable rendered it.
library;

import 'package:flutter/material.dart';

import 'pages/legacy_home_page.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) => const LegacyHomePage();
}

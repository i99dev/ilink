/// Page 2 of the dashboard — wraps the legacy two-pane home (the
/// assistant + apps grid layout that lived as the only home screen
/// before the dashboard rework).
///
/// This is a thin re-export so the dashboard owns layout/scroll
/// physics while the legacy widgets keep ownership of their state.
/// When the legacy panes are eventually retired this file is the
/// only deletion needed.
library;

import 'package:flutter/material.dart';

import '../../../../kernel/ui/responsive/breakpoints.dart';
import '../../../home/presentation/widgets/assistant_panel.dart';
import '../../../home/presentation/widgets/car_status_panel.dart';

class LegacyHomePage extends StatelessWidget {
  const LegacyHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    if (context.isCompact) {
      return const Column(
        children: [
          Expanded(flex: 5, child: AssistantPanel()),
          Expanded(flex: 5, child: CarStatusPanel()),
        ],
      );
    }
    return const Row(
      children: [
        Expanded(flex: 40, child: AssistantPanel()),
        Expanded(flex: 60, child: CarStatusPanel()),
      ],
    );
  }
}

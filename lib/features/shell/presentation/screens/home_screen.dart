import 'package:flutter/material.dart';

import '../../../dashboard/dashboard.dart';

/// Home screen — defers to [DashboardScreen]. The shell owns
/// top-level routing; layout policy lives in the dashboard subtree.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => const DashboardScreen();
}

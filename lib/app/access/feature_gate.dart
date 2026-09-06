import 'package:flutter/widgets.dart';
import 'package:ilink/kernel/access/feature_policy.dart';

/// Local features have no account or purchase requirements.
class FeatureGate extends StatelessWidget {
  const FeatureGate({
    super.key,
    required this.feature,
    required this.child,
    this.lockedMode = LockedRenderMode.replace,
    this.locked,
    this.loading,
  });
  final Feature feature;
  final Widget child;
  final LockedRenderMode lockedMode;
  final Widget Function(BuildContext, Feature)? locked;
  final Widget? loading;
  @override
  Widget build(BuildContext context) => child;
}

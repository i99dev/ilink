import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ilink/app/update/update_orchestrator.dart';

// Flips dialogVisibleProvider when a dialog route is pushed or popped.
// The orchestrator reads this to defer update prompts until the screen is clear.
class OtaNavigatorObserver extends NavigatorObserver {
  OtaNavigatorObserver(this._ref);

  final WidgetRef _ref;

  void _set(bool visible) {
    _ref.read(dialogVisibleProvider.notifier).value = visible;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isDialog(route)) _set(true);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isDialog(route)) _set(false);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isDialog(route)) _set(false);
  }

  // PopupRoute covers AlertDialog, ModalBottomSheet, and CupertinoDialog.
  bool _isDialog(Route<dynamic> route) => route is PopupRoute;
}

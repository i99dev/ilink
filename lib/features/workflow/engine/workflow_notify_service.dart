library;

import 'package:flutter/foundation.dart';

/// Shows an in-app message (SnackBar). Returns `false` when no surface is
/// available (app shell not mounted) so the caller can fall back to the
/// system notification.
typedef ShowInAppMessage = bool Function(String title, String? body);

/// Shows / updates the Android system notification text. Null on platforms
/// without the native voice service (web / iOS / test).
typedef ShowSystemNotification = Future<void> Function(String text)?;

class WorkflowNotifyService {
  WorkflowNotifyService({
    required ShowInAppMessage showInApp,
    ShowSystemNotification showSystem,
  }) : _showInApp = showInApp,
       _showSystem = showSystem;

  final ShowInAppMessage _showInApp;
  final ShowSystemNotification _showSystem;

  /// Dispatch a `notify` action. [args] carries `title` (required by the
  /// compiler), optional `body`, and optional `target` (`inapp` default |
  /// `system`). Returns `{ok}` / `{error}` — the engine's dispatch shape.
  Future<Map<String, Object?>> notify(
    String _,
    Map<String, Object?> args,
  ) async {
    final title = (args['title'] as String?)?.trim();
    if (title == null || title.isEmpty) {
      return {'error': 'notify: missing title'};
    }
    final body = (args['body'] as String?)?.trim();
    final target = (args['target'] as String?) ?? 'inapp';

    // `system` target → straight to the notification shade.
    if (target == 'system') {
      final ok = await _trySystem(title, body);
      return ok ? {'ok': true} : {'error': 'notify: no system channel'};
    }

    // Default in-app; fall back to the system shade when the shell is gone.
    if (_showInApp(title, body)) return {'ok': true};
    final ok = await _trySystem(title, body);
    return ok ? {'ok': true} : {'error': 'notify: no surface available'};
  }

  Future<bool> _trySystem(String title, String? body) async {
    final show = _showSystem;
    if (show == null) return false;
    try {
      await show(body == null || body.isEmpty ? title : '$title — $body');
      return true;
    } catch (e) {
      debugPrint('[workflow] notify system channel failed: $e');
      return false;
    }
  }
}

/// Public surface of the app-actions feature.
///
/// Long-press handlers (installed_apps_strip, mini_app_tile) call
/// [showAppActionsSheet] with an [AppTarget]. Everything else lives
/// internally — registry, controllers, parsers.
library;

export 'domain/app_action.dart' show AppActionKind, AppActionOutcome;
export 'domain/app_meta.dart' show AppMeta;
export 'domain/app_target.dart' show AppTarget, NativeAppTarget, MiniAppTarget;
export 'presentation/app_actions_sheet.dart' show showAppActionsSheet;

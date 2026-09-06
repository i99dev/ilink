import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/i18n/generated/app_localizations.dart';
import '../../../kernel/i18n/locale_controller.dart';
import '../../../kernel/logging/logger.dart';
import '../domain/home_screen_shortcut_service.dart';
import '../domain/mini_app.dart';
import '../domain/mini_app_deep_link.dart';
import 'home_screen_shortcut_service_provider.dart';
import 'mini_app_providers.dart';

/// Outcome surface for [MiniAppShortcutController.pin]. A sealed class
/// so the widget layer can exhaustively map each variant to localized
/// Snackbar copy without defensive default branches — matches the
/// project's "typed errors over strings" quality bar.
sealed class PinOutcome {
  const PinOutcome();
}

class PinSuccess extends PinOutcome {
  const PinSuccess(this.appName);
  final String appName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PinSuccess && other.appName == appName;

  @override
  int get hashCode => appName.hashCode;
}

/// Pinned, but the mini-app's own icon could not be fetched so the
/// bundled launcher icon was used instead. Treated as a partial win
/// rather than a failure — the user still gets a working shortcut.
class PinPartial extends PinOutcome {
  const PinPartial(this.appName);
  final String appName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PinPartial && other.appName == appName;

  @override
  int get hashCode => appName.hashCode;
}

class PinFailed extends PinOutcome {
  const PinFailed(this.reason);
  final PinFailureReason reason;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PinFailed && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;
}

enum PinFailureReason {
  /// The mini-app is no longer in the catalog (delisted or never
  /// existed for the id). Exposed to the deep-link handler too for
  /// the "this mini-app is no longer available" card.
  miniAppRemoved,

  /// The launcher refused the pin request (its implementation returned
  /// false from `requestPinShortcut`).
  launcherRefused,

  /// The platform does not support home-screen shortcuts at all (iOS
  /// today, older Androids, desktop during dev).
  unsupportedPlatform,

  /// Any other platform-channel error. Logged with code + message.
  channelFailure,
}

/// The single orchestrator for everything home-screen-shortcut related
/// — outbound ("add this app") and inbound ("open this app via deep
/// link"). Centralising both flows here means the business rules
/// (catalog lookup, driver-safety gate, icon fallback) have exactly one
/// implementation.
class MiniAppShortcutController extends AsyncNotifier<void> {
  @override
  FutureOr<void> build() {}

  /// Pin the mini-app identified by [id] to the home screen. Handles
  /// catalog lookup, icon resolution (with one-shot fallback), and
  /// error mapping. Never throws — widgets consume [PinOutcome] and
  /// map to Snackbars.
  Future<PinOutcome> pin(String id) async {
    final log = Logger.of(this);
    final catalog = await _safeFetchCatalog();
    final app = _findById(catalog, id);
    if (app == null) {
      log.w('pin($id): not in catalog');
      return const PinFailed(PinFailureReason.miniAppRemoved);
    }

    final iconPath = await _resolveIconOrFallback(app, log);
    final labelLang = _currentLanguageCode();
    final label = app.localizedName(labelLang);

    try {
      await ref
          .read(homeScreenShortcutServiceProvider)
          .pin(
            id: app.id,
            label: label,
            deepLinkUrl: buildMiniAppDeepLink(app.id),
            // Empty string is the sentinel for "use the bundled
            // launcher icon" — Kotlin side reads it and calls
            // IconCompat.createWithResource(R.mipmap.ic_launcher).
            iconFilePath: iconPath ?? '',
          );
      return iconPath == null ? PinPartial(label) : PinSuccess(label);
    } on UnsupportedPlatformError {
      return const PinFailed(PinFailureReason.unsupportedPlatform);
    } on LauncherRefusedPinError {
      return const PinFailed(PinFailureReason.launcherRefused);
    } on ChannelFailureError catch (e) {
      log.e('pin($id) channel failure', error: e);
      return const PinFailed(PinFailureReason.channelFailure);
    }
  }

  /// Resolve [id] to the live catalog row, or null if it was delisted /
  /// never existed. The caller — typically [MiniAppLinkHandler.open] —
  /// then hands the [MiniApp] to [openMiniApp] so the Navigator push +
  /// driver-safety gate stay in the presentation layer.
  ///
  /// Splitting "find app" from "open viewer" here keeps the controller's
  /// [ref] (a plain [Ref]) decoupled from [WidgetRef]-requiring UI APIs
  /// while still centralising the catalog-loading business rule.
  Future<MiniApp?> resolveForLaunch(String id) async {
    final catalog = await _safeFetchCatalog();
    final app = _findById(catalog, id);
    if (app == null) Logger.of(this).w('resolveForLaunch($id): not in catalog');
    return app;
  }

  /// Awaits the catalog, swallowing errors into an empty list — a
  /// deep link shouldn't crash the app if the backend is flaky. The
  /// downstream caller sees an empty catalog and maps to
  /// `miniAppRemoved`, which surfaces the "no longer available" card.
  Future<List<MiniApp>> _safeFetchCatalog() async {
    try {
      return await ref.read(miniAppCatalogProvider.future);
    } catch (e, s) {
      Logger.of(this).e('catalog fetch failed', error: e, stack: s);
      return const [];
    }
  }

  static MiniApp? _findById(List<MiniApp> catalog, String id) {
    for (final app in catalog) {
      if (app.id == id) return app;
    }
    return null;
  }

  /// Returns a local file path for the icon, or null if resolution
  /// failed. The null sentinel travels through to the platform channel
  /// so the Kotlin side can sub in `R.mipmap.ic_launcher` without a
  /// second round-trip. One retry — the resolver already uses a
  /// cache-first strategy, so a failure here almost always means the
  /// icon isn't cacheable (404 / unreachable CDN), which a retry won't
  /// fix.
  Future<String?> _resolveIconOrFallback(MiniApp app, Logger log) async {
    try {
      return await ref.read(miniAppIconResolverProvider).resolve(app.icon);
    } on IconResolveFailedError catch (e) {
      log.w('icon resolve failed for ${app.id}: ${e.cause}');
      return null;
    } catch (e, s) {
      log.w('unexpected icon resolver error for ${app.id}: $e');
      log.e('stack', stack: s);
      return null;
    }
  }

  String _currentLanguageCode() {
    return ref.read(localeControllerProvider).value?.locale.languageCode ??
        'en';
  }
}

/// Single provider — matches `miniAppCatalogProvider` / `localProfileProvider`
/// shape so the mini-apps feature stays internally consistent.
final miniAppShortcutControllerProvider =
    AsyncNotifierProvider<MiniAppShortcutController, void>(
      MiniAppShortcutController.new,
    );

/// UI-level copy mapping. Kept next to the controller so adding a new
/// [PinOutcome] variant forces a matching localised branch.
String pinOutcomeMessage(S t, PinOutcome outcome) {
  switch (outcome) {
    case PinSuccess(:final appName):
      return t.miniAppsAddToHomeScreenSuccess(appName);
    case PinPartial(:final appName):
      return t.miniAppsAddToHomeScreenPartial(appName);
    case PinFailed(:final reason):
      switch (reason) {
        case PinFailureReason.miniAppRemoved:
          return t.miniAppsDeepLinkUnknownApp;
        case PinFailureReason.launcherRefused:
          return t.miniAppsAddToHomeScreenRefused;
        case PinFailureReason.unsupportedPlatform:
          // Shouldn't normally render — the action is hidden when
          // unsupported — but map anyway for defensive UI.
          return t.miniAppsAddToHomeScreenError;
        case PinFailureReason.channelFailure:
          return t.miniAppsAddToHomeScreenError;
      }
  }
}

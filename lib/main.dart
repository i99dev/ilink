import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'features/_car_domain/router/command_router.dart';
import 'features/shortcuts/state/floating_shortcuts_sync.dart';
import 'features/voice/ondevice/ondevice_voice_autoarm.dart';
import 'sdk/car/gated_dispatcher.dart';
import 'sdk/car/sdk_config.dart';
import 'app/app_navigator.dart';
import 'platform/observability/observability.dart';
import 'kernel/config/app_config.dart';
import 'kernel/config/config_provider.dart';
import 'platform/deep_link/deep_link_listener.dart';
import 'platform/deep_link/link_router.dart';
import 'platform/deep_link/link_router_provider.dart';
import 'kernel/i18n/generated/app_localizations.dart';
import 'kernel/i18n/locale_controller.dart';
import 'features/themes/state/theme_providers.dart';
import 'kernel/logging/logger.dart';
import 'app/lifecycle/app_listeners.dart';
import 'app/lifecycle/boot_sequence.dart';
import 'app/lifecycle/session_bootstrap.dart';
import 'kernel/settings/app_settings.dart';
import 'features/mini_apps/state/mini_app_link_handler.dart';
import 'features/radio/state/m3u_link_handler.dart';
import 'app/gate/app_gate.dart';
import 'features/radio/providers.dart';
import 'features/voice/presentation/voice_tool_overrides.dart';
import 'features/shell/presentation/widgets/daemon_setup_overlay.dart';
import 'features/splash/presentation/splash_screen.dart';
import 'app/update/update_controller.dart';
import 'app/update/update_orchestrator.dart';
import 'app/update/update_state.dart';
import 'app/update/ui/ota_navigator_observer.dart';
import 'app/update/ui/update_prompt.dart';
import 'features/shell/presentation/dash_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Local error boundary; no analytics SDK or outbound reporting.
  await Observability.runApp(_bootstrap);
}

/// Feeds the bundled fonts' OFL text to [LicenseRegistry] so it appears in
/// the standard Flutter license page. Reads the asset lazily — the registry
/// only pulls the stream when licenses are actually shown.
void _registerBundledFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(const ['Cairo', 'Inter'], text);
  });
}

Future<void> _bootstrap() async {
  // The bundled Cairo and Inter faces are SIL OFL 1.1. Clause 2 requires
  // the license to travel with the fonts in every redistribution, the
  // APK included, so register it with Flutter's license registry (and
  // ship assets/fonts/OFL.txt) rather than leaving it repo-only.
  _registerBundledFontLicenses();
  // Needed so DateFormat('EEE'/'MMM', 'ar') returns Arabic names.
  await initializeDateFormatting();
  final config = AppConfig.fromEnvironment();
  Logger.configure(config.logLevel);
  // Prime SharedPreferences once at startup so features that need
  // synchronous access (e.g. radio favourites) can read it without an
  // await-dance. SettingsController also uses the same cached instance
  // internally; calling getInstance() here doesn't allocate a second one.
  final prefs = await SharedPreferences.getInstance();
  // Durable home for user-imported radio playlists. FileUserPlaylistStore
  // creates the directory lazily on first write; we only need the
  // resolved path so the provider override below can wire it in
  // synchronously.
  final userPlaylistDir = Directory(
    '${(await getApplicationSupportDirectory()).path}/user_playlists',
  );
  // Cap the image cache so cached_network_image + heroes don't grow
  // beyond what the IVI's GPU can swap. The Flutter default
  // (100 MB / 1000 entries) is way over the working set on this
  // device and pressures the LRU eviction path.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 32 << 20; // 32 MB
  PaintingBinding.instance.imageCache.maximumSize = 200;
  // NOTE: previously `_bootstrap` also awaited `JustAudioBackground.init`
  // and `GoogleFonts.pendingFonts(...)` and called
  // `SystemChrome.setPreferredOrientations` /
  // `setEnabledSystemUIMode`. Those moved out:
  //   * JustAudioBackground.init → memoised inside `radioPlayerProvider`
  //     (lib/features/radio/providers.dart), triggered on first read.
  //   * Cairo + Inter ship as bundled font assets via the bundle
  //     worktree's `flutter.fonts:` block; no runtime fetch needed.
  //   * SystemChrome calls → `_DashAppState.initState` post-frame so
  //     the first paint is not blocked. The AndroidManifest already
  //     locks orientation; the postframe call is belt-and-suspenders.
  runApp(
    ProviderScope(
      overrides: [
        // Override the BASE provider — the public `appConfigProvider`
        // is now derived (base + runtime backend-URL override). See
        // lib/kernel/config/config_provider.dart.
        appConfigBaseProvider.overrideWithValue(config),
        powertrainProvider.overrideWithValue(config.powertrain),
        sharedPreferencesProvider.overrideWithValue(prefs),
        userPlaylistDirProvider.overrideWithValue(userPlaylistDir),
        // SDK runtime config — keeps the SDK self-contained (no
        // reach into AppConfig from lib/sdk/). See
        // lib/sdk/car/sdk_config.dart and the boundary rule in
        // docs/car-sdk-layers/.
        sdkConfigProvider.overrideWithValue(SdkConfig(mockCar: config.mockCar)),
        // Inject the gated dispatcher so the SDK's `client.dispatch`
        // routes through the app's CarCommandRouter (audit / integrity /
        // rate-limit / stationary). The SDK doesn't import the router
        // directly — see lib/sdk/car/gated_dispatcher.dart.
        gatedDispatcherProvider.overrideWith((ref) {
          final router = ref.read(carCommandRouterProvider);
          return (action, args, {caller}) =>
              router.dispatch(action, args, caller: caller);
        }),
        // Single registration point for every feature that wants to
        // claim a URL. Adding a new deep-link type is a new handler
        // class + one more entry in this list — `LinkRouter` itself
        // stays feature-agnostic.
        linkHandlersProvider.overrideWithValue(const <LinkHandler>[
          MiniAppLinkHandler(),
          M3uPlaylistLinkHandler(),
        ]),
      ],
      child: const DashApp(),
    ),
  );
}

class DashApp extends ConsumerStatefulWidget {
  const DashApp({super.key});

  @override
  ConsumerState<DashApp> createState() => _DashAppState();
}

class _DashAppState extends ConsumerState<DashApp> {
  late final OtaNavigatorObserver _otaObserver;

  @override
  void initState() {
    super.initState();
    // Instantiate after ProviderScope is available via ref.
    _otaObserver = OtaNavigatorObserver(ref);
    // Defer SystemChrome calls to after first paint so the boot
    // critical path doesn't block on these platform-channel calls.
    // The AndroidManifest already locks orientation, so there's no
    // visible flicker if the postframe fires a beat later.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.immersiveSticky,
        overlays: const [],
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    // MaterialApp itself doesn't watch locale/themeMode — those reads
    // moved into the inner [_AppShell] consumer so a locale or theme
    // flip rebuilds only the shell, not the whole MaterialApp tree
    // (which carries a Navigator + scroll behavior config).
    return _AppShell(otaObserver: _otaObserver);
  }
}

class _AppShell extends ConsumerWidget {
  const _AppShell({required this.otaObserver});

  final OtaNavigatorObserver otaObserver;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lang =
        ref.watch(localeControllerProvider.select((a) => a.value)) ??
        AppLang.en;
    // Watch themeMode so the switcher is live. While settings are still
    // loading (first-launch, pre-SharedPreferences-hydration) we fall
    // back to the default — same value the AppSettings constructor uses.
    final themeMode =
        ref.watch(settingsProvider.select((a) => a.value?.themeMode)) ??
        AppSettings.defaultThemeMode;
    // Resolve the active theme's light + dark ThemeData. When no theme
    // is selected (activeThemeId empty), this returns the built-in
    // AppTheme.light()/dark() — byte-identical to the historical look,
    // so the feature is inert until the user picks one. A live Apply
    // rebuilds this select and re-themes the whole shell with no
    // restart.
    final resolvedTheme = ref.watch(
      activeThemeDataProvider(lang.locale.languageCode),
    );
    // Phase 2 of human-in-the-loop framework: registers per-tool
    // custom widgets (weather card, future restaurant picker) on
    // [SheetInteractivePrompter]. Idempotent — re-watching during
    // hot-reload overwrites by tool name.
    ref.watch(voiceToolOverridesProvider);
    // Warm optional catalogs independently of local device startup.
    ref.watch(sessionBootstrapTriggerProvider);
    // Keep the on-device "Hey BYD" detector armed in lockstep with the
    // wakeWordEnabled setting. Inert until a Vosk model is provisioned AND
    // the setting is enabled (defaults OFF) — no behaviour change on the
    // fleet until deliberately turned on.
    ref.watch(onDeviceVoiceAutoArmProvider);
    // Keep the floating per-app shortcut buttons in lockstep with the
    // pinned-apps setting. Inert until the user pins an app (list empty).
    ref.watch(floatingShortcutsSyncProvider);
    return MaterialApp(
      title: 'Dash',
      // Single app-wide navigator key — exposed via
      // ``appNavigatorKeyProvider`` so background work (voice
      // consent sheet, push notification handler, async tool
      // dispatch) can surface UI without a stale BuildContext.
      navigatorKey: appNavigatorKey,
      // Root messenger key so non-widget listeners
      // can show app-wide SnackBars without a BuildContext.
      scaffoldMessengerKey: appScaffoldMessengerKey,
      theme: resolvedTheme.light,
      darkTheme: resolvedTheme.dark,
      // A selected theme owns its brightness (resolvedTheme.mode); the
      // user's System/Light/Dark choice governs only the inert default.
      themeMode: resolvedTheme.mode ?? themeMode,
      // Default MaterialScrollBehavior only allows touch/stylus drag,
      // so PageView swipe doesn't work with a mouse on Chrome/desktop.
      // Explicitly include mouse + trackpad so the shell's PageView is
      // swipeable in every target (touch on the IVI, mouse on web/dev).
      scrollBehavior: const _SwipeAnywhereScrollBehavior(),
      debugShowCheckedModeBanner: false,
      locale: lang.locale,
      supportedLocales: S.supportedLocales,
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      navigatorObservers: [otaObserver],
      // DaemonSetupOverlay sits between _Gate and SplashGate so the
      // splash still covers it on cold boot (no overlay flash before
      // the brand finishes), but every post-splash screen — onboarding,
      // shell, mini-apps — renders the overlay on top when the
      // loopback-ADB bring-up triggers it.
      home: const SplashGate(
        child: Stack(
          fit: StackFit.expand,
          children: [_Gate(), DaemonSetupOverlay()],
        ),
      ),
    );
  }
}

class _Gate extends ConsumerStatefulWidget {
  const _Gate();

  @override
  ConsumerState<_Gate> createState() => _GateState();
}

class _GateState extends ConsumerState<_Gate> {
  // Guards the one-shot boot-sequence kick so it fires exactly once,
  // after the license gate resolves to activated — not on every
  // rebuild and not before the gate has cleared.
  bool _bootStarted = false;

  void _startBootOnce() {
    if (_bootStarted) return;
    _bootStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      buildBootSequence(ref).start();
    });
  }

  @override
  Widget build(BuildContext context) {
    _startBootOnce();
    return _buildBootGate(context);
  }

  Widget _buildBootGate(BuildContext context) {
    // Show the update prompt whenever the orchestrator parks a manifest.
    // Listener lives here (not inside BootSequence) because it needs the
    // navigator's BuildContext to call `showDialog`.
    ref.listen<UpdateAvailable?>(promptUpdateProvider, (prev, next) {
      otaDiagLog(
        'promptUpdateProvider changed prev=${prev?.manifest.versionCode} '
        'next=${next?.manifest.versionCode} mounted=${context.mounted}',
      );
      if (next != null && context.mounted) {
        otaDiagLog(
          'showing UpdatePromptDialog vc=${next.manifest.versionCode}',
        );
        showDialog<void>(
          context: context,
          barrierDismissible: !next.manifest.requiresForceUpdate(
            ref.read(installedVersionCodeProvider).value ?? 0,
          ),
          builder: (_) => UpdatePromptDialog(manifest: next.manifest),
        );
      }
    });

    final bootWipe = ref.watch(bootWipeResumeProvider);
    // Finish the one-time removal of retired credentials before showing UI.
    if (bootWipe.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final settings = ref.watch(settingsProvider);
    return settings.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      // Diagnostic-friendly error display: the previous version
      // showed only `e.toString()`, which for some Riverpod errors
      // (e.g. `CircularDependencyError` printed as
      // `Provider<AppConfig>#<hash>`) gives no actionable signal.
      // Print runtimeType + message + stack so the next failure is
      // debuggable from a screenshot.
      error: (e, st) => Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Builder(
              builder: (ctx) => Text(
                '${S.of(ctx).settingsErrorPrefix('')}\n'
                'type: ${e.runtimeType}\n'
                'msg : $e\n'
                'stack:\n$st',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
        ),
      ),
      data: (_) {
        // Post-settings boot gates, in order (onboarding → auth). Each is
        // a pure step in `kPostSettingsGates`; render the first non-pass
        // screen. With the auth gate off (default) this is exactly the old
        // behavior: onboarding-incomplete → OnboardingScreen, else shell.
        final blocking = firstBlockingGate(ref, kPostSettingsGates);
        if (blocking is GateLoading) {
          return blocking.screen ??
              const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (blocking is GateBlock) return blocking.screen;
        return const DeepLinkListener(child: DashShell());
      },
    );
  }
}

class _SwipeAnywhereScrollBehavior extends MaterialScrollBehavior {
  const _SwipeAnywhereScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.unknown,
  };
}

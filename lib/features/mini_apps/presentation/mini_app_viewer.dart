import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as path;

import '../../../platform/location/location_service.dart';
import '../../../platform/observability/observability.dart';
import '../../../app/update/update_orchestrator.dart';
import '../../../kernel/i18n/locale_controller.dart';
import '../../../kernel/settings/app_settings.dart';
import '../../../kernel/services/optional_services.dart';
import '../../admin_mini_apps/domain/admin_dispatcher.dart';
import '../../admin_mini_apps/state/admin_dispatcher_provider.dart';
import '../../profile/state/local_profile_provider.dart';
import '../../workflow/bridge/workflow_bridge_service.dart';
import '../../workflow/engine/compiled_workflow.dart';
import '../../workflow/engine/workflow_engine_provider.dart';
import '../bridge/car_bridge_service.dart';
import '../packaging/pkg_native_bridge.dart';
import '../bridge/family_event_pusher.dart';
import '../data/mini_app_bridge_config.dart';
import '../data/mini_app_install_storage.dart';
import '../data/local_mini_app_grants.dart';
import '../domain/mini_app.dart';
import '../state/admin_catalog_provider.dart';
import '../state/family_executor_provider.dart';
import 'beta_consent_sheet.dart';
import 'launch_mini_app.dart';

part 'mini_app_viewer_workflow_handlers.dart';
part 'mini_app_viewer_permissions.dart';

/// Sandboxed WebView for a single mini-app.
///
/// Security invariants — all of these must hold before anything the
/// mini-app renders can be considered trustworthy, and they're
/// independent checks on purpose (belt and suspenders):
///
///   1. The initial [MiniApp.url] must pass [isAllowedMiniAppOrigin].
///      If it doesn't, the WebView never starts — we render an inline
///      error surface instead.
///   2. Every navigation (redirects, clicks, frame loads) is re-checked
///      via [shouldOverrideUrlLoading]. Off-allowlist navigations are
///      cancelled; on-allowlist ones continue.
///   3. [onLoadStart] repeats the check. Belt + suspenders in case a
///      platform-specific quirk bypasses the override.
///   4. The JS bridge exposes a fixed handler set (`getContext`, `callApi`,
///      `_admin.exec`, plus the `car.*` family routed through
///      [CarBridgeService]). `callApi` further restricts to
///      [isAllowedMiniAppApiPath] + [isAllowedMiniAppApiMethod] — car
///      control, auth, billing, and anything else the host can do is
///      NOT reachable from the sandbox. `_admin.exec` routes through
///      [AdminMiniAppDispatcher], which gates every privileged op on
///      template lookup → consent → cap → revocation; a non-privileged
///      mini-app fails at "unknown_template" before any cap check.
///   5. The access token never crosses the bridge. `callApi` proxies
///      through the host's [ApiClient], so the token stays in the
///      host process. Privileged-op capability tokens are owned
///      entirely by the dispatcher (Phase-9 host-owned-caps) and
///      never enter the WebView.
/// Our own package — never offered as a launch target in the workflow
/// canvas's app picker (launching ilink from its own automation is
/// meaningless). Mirrors `_kHostPackage` in `installed_apps_provider`.
const String _kWorkflowHostPackage = 'com.i99dev.ilink';

/// Consent is independent of the installed app's declared origin allow-list.
bool miniAppRequestAllowedWithConsent(
  Uri url, {
  required Uri installRoot,
  required List<String> networkOrigins,
  required bool networkEnabled,
}) {
  if (url.scheme == 'file') {
    if (url.host.isNotEmpty || url.userInfo.isNotEmpty || url.hasPort) {
      return false;
    }
    return path.isWithin(
      path.normalize(installRoot.toFilePath()),
      path.normalize(url.toFilePath()),
    );
  }
  if (url.scheme == 'data' || url.scheme == 'blob') return true;
  return networkEnabled && isAllowedMiniAppRequest(url, networkOrigins);
}

class MiniAppViewer extends ConsumerStatefulWidget {
  const MiniAppViewer({
    super.key,
    required this.app,
    required this.localIndexPath,
  });

  final MiniApp app;

  /// Filesystem path of the installed bundle's `index.html`. Resolved
  /// by [openMiniApp] from [InstalledMiniAppStore] before this widget
  /// is constructed — the viewer doesn't fall back to a network URL,
  /// keeping every render path through the hash-verified local copy.
  final String localIndexPath;

  @override
  ConsumerState<MiniAppViewer> createState() => _MiniAppViewerState();
}

class _MiniAppViewerState extends ConsumerState<MiniAppViewer> {
  InAppWebViewController? _controller;
  bool _disposed = false;
  int _networkEpoch = 0;

  /// Single cancellation token for every host-API call this viewer
  /// makes via the `callApi` bridge. Cancelled in [dispose] so a
  /// backgrounded request from the mini-app doesn't complete into a
  /// torn-down state.
  final CancelToken _lifetimeCancel = CancelToken();

  /// `file://` URI of the install root directory (parent of
  /// `index.html`). Used as the navigation prefix gate so the
  /// WebView can fetch sibling assets (CSS / JS) but cannot escape
  /// out of the install dir.
  late final Uri _installRoot = _resolveInstallRoot(widget.localIndexPath);

  late final Uri _indexUri = Uri.file(widget.localIndexPath);

  // ── car.* bridge state ──────────────────────────────────────────
  //
  // The new [CarBridgeService] (single owner of every car-data bridge
  // call across the process) holds subscription state keyed by
  // `subscriptionId`. The viewer is a thin shim: it generates ids,
  // forwards calls to the service, and tears its own subscriptions
  // down on dispose via [CarBridgeService.unsubscribeAllForViewer]
  // (for signal subs) plus an explicit loop over
  // [_connectionSubscriptionIds] (the connection channel is keyed by
  // id, not viewer).

  /// Stable per-viewer id, used as the `viewerId` argument on every
  /// `car.subscribe` call so the service can drain this viewer's
  /// subscriptions in one shot on dispose.
  final String _viewerId = const Uuid().v4();

  /// Tracked `car.subscribe` ids. The service owns the canonical
  /// state; this set is just so we can log how many subs leaked at
  /// dispose time (none should — the bulk-drain handles it).
  final Set<String> _subscriptionIds = <String>{};

  /// Tracked `car.connection.subscribe` ids. The service indexes
  /// these by id (not viewerId), so dispose iterates this set and
  /// calls `connectionUnsubscribe` for each.
  final Set<String> _connectionSubscriptionIds = <String>{};

  CarBridgeService get _carBridge => ref.read(carBridgeServiceProvider);

  static Uri _resolveInstallRoot(String indexPath) {
    final indexUri = Uri.file(indexPath);
    final segments = List<String>.from(indexUri.pathSegments)..removeLast();
    return indexUri.replace(pathSegments: [...segments, '']);
  }

  bool _sessionCounted = false;
  // Captured at increment time so dispose() can decrement without
  // calling `ref.read(...)` — Riverpod forbids that during dispose.
  VoidCallback? _decrementSessionCount;

  @override
  void initState() {
    super.initState();
    // Breadcrumb the lifecycle. The viewer ↔ pkg.launch crash
    // hypothesis needs the init/dispose chain to verify whether
    // the WebView is still mounted when a launch reply posts back.
    Observability.breadcrumb(
      category: 'mini_app.viewer',
      message: 'init',
      data: {'appId': widget.app.id, 'version': widget.app.version},
    );
    // Sentry Logs (separate from breadcrumbs — these are queryable in
    // the Logs UI without an exception to anchor them). Lets triagers
    // pivot from "user complained about pkg-launcher on a Leopard 5"
    // to "show me every load attempt of pkg-launcher on l5" without
    // needing a crash. The level set per call type:
    //   info  — lifecycle (load start, bridge ready, dispose)
    //   warn  — bridge handler returned a structured error envelope
    //   error — JS console.error / WebView render failure

    // Tag the Sentry scope with the active mini-app so every event
    // emitted while the viewer is open carries it on the issue card.
    Observability.setActiveMiniApp(
      appId: widget.app.id,
      version: widget.app.version,
    );
    // Defer mutation past the build frame so we don't write to a
    // provider while a parent is still building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = ref.read(activeMiniAppSessionCountProvider.notifier);
      notifier.increment();
      _decrementSessionCount = notifier.decrement;
      _sessionCounted = true;
    });
  }

  @override
  void dispose() {
    Observability.breadcrumb(
      category: 'mini_app.viewer',
      message: 'dispose',
      data: {'appId': widget.app.id},
    );

    // Clear the active-mini-app tag so any event that fires AFTER the
    // viewer closes (background timer, dangling future, etc.) doesn't
    // keep claiming a stale mini-app session.
    Observability.clearActiveMiniApp();
    _disposed = true;
    if (_sessionCounted) {
      _decrementSessionCount?.call();
    }
    _lifetimeCancel.cancel('mini-app viewer disposed');
    // Drain car.* subscriptions owned by this viewer. The service
    // tolerates calls after its Riverpod scope is torn down (no-ops
    // for unknown ids), so this is safe even on a hot-restart race.
    final bridge = _carBridge;
    bridge.unsubscribeAllForViewer(_viewerId);
    for (final id in _connectionSubscriptionIds) {
      bridge.connectionUnsubscribe(id);
    }
    _subscriptionIds.clear();
    _connectionSubscriptionIds.clear();
    // Clear per-WebView Chromium caches before the controller dies —
    // mini-app sessions cache fonts, fetched JSON, IndexedDB blobs in
    // the renderer's per-process store. Without this, the cache pages
    // stay resident long after the WebView widget is torn down (the
    // platform's per-process renderer doesn't garbage-collect them
    // until the entire process exits). A pool-based recycler is the
    // proper long-term fix; this is the worktree-budget fallback that
    // covers the same memory footprint at the cost of cold cache on
    // re-open. See worktree report for trade-off.
    final controller = _controller;
    if (controller != null) {
      // Fire-and-forget — the controller is about to detach; we just
      // want the platform-side eviction to run before that happens.
      // `InAppWebViewController.clearAllCache()` is the static-style
      // entry point on flutter_inappwebview that drops the renderer's
      // per-process cache; per the plugin docs (doc id
      // `/pichillilorenzo/flutter_inappwebview`) this covers HTTP
      // cache + DOM storage that would otherwise outlive the widget.
      // ignore: discarded_futures
      InAppWebViewController.clearAllCache();
      // ignore: discarded_futures
      controller.clearHistory();
    }
    super.dispose();
  }

  /// True iff [url] is one of:
  ///   * a `file://` URL whose path is under the install root, or
  ///   * a HTTPS URL on the existing miniapps allow-list (lets a
  ///     mini-app fetch fonts / external API endpoints exposed by
  ///     the bridge without breaking the sandbox).
  ///
  /// Anything else — `http://`, `data:`, `about:`, `file://` outside
  /// the install root — is rejected.
  bool _navigationAllowed(Uri? url) {
    if (url == null) return false;
    if (url.scheme == 'file') {
      return miniAppRequestAllowedWithConsent(
        url,
        installRoot: _installRoot,
        networkOrigins: widget.app.network,
        networkEnabled: false,
      );
    }
    // Top-level navigation is allowed to the global bundle origin OR an
    // origin this app declared in its manifest `network`. (This is also the
    // navigation half of the form-action / top-nav exfil defense — CSP's
    // navigate-to never shipped on the frozen WebView, so the gate is here.)
    return ref.read(serviceEnabledProvider(OptionalService.downloads)) &&
        isAllowedMiniAppOriginForApp(url, widget.app.network);
  }

  @override
  Widget build(BuildContext context) {
    final lang =
        ref.watch(
          localeControllerProvider.select((a) => a.value?.locale.languageCode),
        ) ??
        Localizations.localeOf(context).languageCode;
    final name = widget.app.localizedName(lang);

    // Drive-state gating removed (2026-05-01) — drivers can open and
    // keep mini-apps open regardless of vehicle motion. See
    // `launch_mini_app.dart` for the matching open-time change.

    return Scaffold(
      appBar: AppBar(
        // When loading a beta build, show the BETA badge next to the
        // app name so the tester always knows which track they're on.
        title: widget.app.isBeta
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 8),
                  const BetaBadge(),
                ],
              )
            : Text(name),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller?.reload(),
          ),
        ],
      ),
      body: _buildWebView(),
    );
  }

  Widget _buildWebView() {
    final networkEnabled = ref.watch(
      serviceEnabledProvider(OptionalService.downloads),
    );
    ref.listen(optionalServicesProvider, (previous, next) {
      final wasEnabled =
          previous?.value?.contains(OptionalService.downloads) ?? false;
      final enabled = next.value?.contains(OptionalService.downloads) ?? false;
      if (wasEnabled && !enabled) {
        final controller = _controller;
        if (controller != null) {
          unawaited(
            controller.setSettings(
              settings: InAppWebViewSettings(blockNetworkLoads: true),
            ),
          );
          unawaited(controller.stopLoading());
        }
        // Destroy the old document (and its workers/sockets), then reopen the
        // installed local bundle with the new policy. Persistent data remains.
        _carBridge.unsubscribeAllForViewer(_viewerId);
        for (final id in _connectionSubscriptionIds) {
          _carBridge.connectionUnsubscribe(id);
        }
        _subscriptionIds.clear();
        _connectionSubscriptionIds.clear();
        setState(() => _networkEpoch++);
      }
    });
    // Read the cached catalog snapshot synchronously. The provider is
    // a ``FutureProvider``; reading it via ``.valueOrNull`` returns
    // ``null`` while loading and falls back to the previously-cached
    // value once available. Either way we want the WebView to mount
    // *now* — passing an empty list is safe (the SDK falls through
    // to its dev catalog or operates with zero privileged ops) and
    // the host can ``ref.invalidate(adminCatalogProvider)`` later to
    // refresh the local catalog. We don't block on the future here because
    // every additional ``await`` before WebView creation is a
    // visible delay the user would notice in a car UI.
    final adminCatalog =
        ref.watch(adminCatalogProvider).asData?.value ??
        const <Map<String, dynamic>>[];
    // The FutureProvider rarely resolves before WebView creation on
    // the first open of a session — so the initialUserScripts inject
    // an empty array. Push the value back via evaluateJavaScript when
    // the future resolves so the page can re-read
    // window.__i99dashAdminCatalog and rebuild its snapshot.
    ref.listen<AsyncValue<List<Map<String, dynamic>>>>(adminCatalogProvider, (
      prev,
      next,
    ) {
      final value = next.asData?.value;
      if (value == null) return;
      final controller = _controller;
      if (controller == null) return;
      controller.evaluateJavascript(
        source: 'window.__i99dashAdminCatalog = ${jsonEncode(value)};',
      );
    });
    return InAppWebView(
      key: ValueKey('$networkEnabled:$_networkEpoch'),
      initialUrlRequest: URLRequest(url: WebUri.uri(_indexUri)),
      initialSettings: _lockedSettings(networkEnabled: networkEnabled),
      initialUserScripts: brandedGlobalAliasUserScripts(
        adminCatalog: adminCatalog,
        networkOrigins: widget.app.network,
        networkEnabled: networkEnabled,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        _registerHandlers(controller);
      },
      onLoadStop: (controller, url) {
        // The DOM is ready — push the latest cached catalog. The
        // ``initialUserScripts`` injection runs at AT_DOCUMENT_START
        // with whatever the FutureProvider held at WebView-create
        // time (often an empty list on first open). This second push
        // catches up after the future resolves.
        final value = ref.read(adminCatalogProvider).asData?.value;
        if (value != null) {
          controller.evaluateJavascript(
            source: 'window.__i99dashAdminCatalog = ${jsonEncode(value)};',
          );
        }
      },
      shouldOverrideUrlLoading: (controller, action) async {
        return _navigationAllowed(action.request.url)
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL;
      },
      onLoadStart: (controller, url) {
        // Defence in depth — cancel an in-flight load that slipped past
        // the override (platform quirks, iframes with bridge mode, …).
        if (!_navigationAllowed(url)) {
          controller.stopLoading();
        }
      },
      // Native browser grants are shared by file origins and cannot enforce
      // per-bundle revocation. The JS compatibility shim uses location.read.
      onGeolocationPermissionsShowPrompt: (controller, origin) async =>
          GeolocationPermissionShowPromptResponse(
            origin: origin,
            allow: false,
            retain: false,
          ),
      // PRIMARY egress gate. Every WebView request (fetch / XHR / img /
      // script / css / form POST / beacon / WebSocket handshake), from the
      // main frame AND child frames, passes through here. Bundle-local
      // schemes (file/data/blob) pass; https/wss pass only for the global
      // bundle origin or an origin this app declared in its manifest
      // `network`; everything else is blocked with a 403 — reliable even
      // where the frozen WebView's CSP parsing is not. See
      // [isAllowedMiniAppRequest].
      shouldInterceptRequest: (controller, request) async {
        final url = Uri.tryParse(request.url.toString());
        // Unparseable (WebView-internal) requests are not egress — allow,
        // rather than risk blocking a benign internal load.
        if (url != null &&
            miniAppRequestAllowedWithConsent(
              url,
              installRoot: _installRoot,
              networkOrigins: widget.app.network,
              networkEnabled: ref.read(
                serviceEnabledProvider(OptionalService.downloads),
              ),
            )) {
          return null;
        }
        Observability.breadcrumb(
          category: 'mini_app.egress_blocked',
          message: url?.toString() ?? '(invalid URL)',
          data: {'appId': widget.app.id},
        );
        return WebResourceResponse(
          statusCode: 403,
          reasonPhrase: 'egress blocked by app network policy',
        );
      },
      // Block scripted window.open() entirely — a new window would escape
      // the per-app CSP + intercept context. The
      // `javaScriptCanOpenWindowsAutomatically=false` setting only blocks
      // *automatic* popups; this refuses scripted ones too.
      onCreateWindow: (controller, action) async => false,
    );
  }

  /// Settings the WebView must *always* run under. These are the
  /// security-relevant ones — everything else is left at the plugin
  /// default. Changing these must go through review.
  ///
  /// `allowFileAccessFromFileURLs` is true so the bundled
  /// index.html can `<script src="./app.js">` / fetch sibling JSON
  /// assets — without it, file:// pages can't read each other on
  /// Android (a 2010-era SOP defence that's now a footgun for the
  /// install model). Combined with the navigation prefix gate above
  /// (which only allows file:// under the install root), the
  /// trust boundary is "this app's installed bundle" — the same
  /// isolation guarantee a sandboxed origin gives, just enforced at
  /// the navigation layer instead of via SOP. `allowUniversal` stays
  /// false: a file:// page must not be able to xhr arbitrary http
  /// hosts.
  InAppWebViewSettings _lockedSettings({required bool networkEnabled}) =>
      InAppWebViewSettings(
        blockNetworkLoads: !networkEnabled,
        useShouldInterceptRequest: true,
        useShouldOverrideUrlLoading: true,
        javaScriptEnabled: true,
        domStorageEnabled: true,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: false,
        mediaPlaybackRequiresUserGesture: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
        isInspectable: kDebugMode,
        javaScriptCanOpenWindowsAutomatically: false,
        supportZoom: false,
        // Browser-compatible location calls use the scoped host bridge shim.
        geolocationEnabled: false,
      );

  // ═════════════════════════════════════════════════════════════════
  // JS bridge
  //
  // Mini-apps reach into these via:
  //   const ctx = await window.flutter_inappwebview.callHandler('getContext');
  //   const list = await window.flutter_inappwebview.callHandler('car.list');
  //   const id = await window.flutter_inappwebview.callHandler(
  //     'car.subscribe', {names: ['vehicle.speed']});
  //
  // To reach an external HTTP API, a mini-app uses a plain browser
  // `fetch()` to an origin it declared in its manifest `network` field;
  // there is no host-proxied `callApi` handler any more (the request
  // interceptor + per-app CSP enforce the declared egress allow-list).
  //
  // Keep the set small on purpose. Adding a new handler is a design
  // decision: it widens the mini-app's capability surface. The full
  // car.* surface is one cohesive family routed through
  // [CarBridgeService]; the only non-car handlers are getContext and
  // _admin.exec.
  // ═════════════════════════════════════════════════════════════════

  void _registerHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'getContext',
      callback: _handleGetContext,
    );
    controller.addJavaScriptHandler(
      handlerName: '_admin.exec',
      callback: _handleAdminExec,
    );
    // ── car.* ─────────────────────────────────────────────────────
    // Every car-data bridge call (list, read, subscribe,
    // unsubscribe, command, identity, asset, connection.*) routes
    // through the single [CarBridgeService]. The viewer is just a
    // shim that:
    //   * generates `subscriptionId`s for sub/unsub pairs
    //   * tracks which subs this viewer owns (for dispose drain)
    //   * forwards push callbacks into the WebView via
    //     `evaluateJavascript('window.__i99dashEvents.dispatch(...)')`.
    _registerScopedHandler(
      controller,
      handlerName: 'car.list',
      callback: _handleCarList,
    );
    // ── workflow.* + voice.status ─────────────────────────────────
    // The authoring-canvas surface (catalog/CRUD/templates/test) plus the
    // voice-readiness probe. Extracted to `mini_app_viewer_workflow_handlers`
    // to keep this file under the maintainability LOC ratchet.
    _registerWorkflowHandlers(controller);
    _registerScopedHandler(
      controller,
      handlerName: 'car.read',
      callback: _handleCarRead,
    );
    _registerScopedHandler(
      controller,
      handlerName: 'car.subscribe',
      callback: _handleCarSubscribe,
    );
    _registerScopedHandler(
      controller,
      handlerName: 'car.unsubscribe',
      callback: _handleCarUnsubscribe,
    );
    _registerScopedHandler(
      controller,
      handlerName: 'car.command',
      callback: _handleCarCommand,
    );
    _registerScopedHandler(
      controller,
      handlerName: 'car.identity',
      callback: _handleCarIdentity,
    );
    _registerScopedHandler(
      controller,
      handlerName: 'car.asset',
      callback: _handleCarAsset,
    );
    _registerScopedHandler(
      controller,
      handlerName: 'car.connection.subscribe',
      callback: _handleCarConnectionSubscribe,
    );
    _registerScopedHandler(
      controller,
      handlerName: 'car.connection.unsubscribe',
      callback: _handleCarConnectionUnsubscribe,
    );
    // ── capabilities ──────────────────────────────────────────────
    // Forward-compat handshake. SDKs call this once on first
    // `client.capabilities()` / `client.has(scope)` to learn what
    // the host implements. Returns the bridge version + the flat
    // handler name list so the SDK can introspect feature presence
    // without a probe call.
    controller.addJavaScriptHandler(
      handlerName: 'capabilities',
      callback: _handleCapabilities,
    );
    // `location.read` — the car's real position from the centralised
    // host LocationService (Geolocator/FusedLocation), the same
    // reliable path onboarding uses. Mini-apps (weather-ahead,
    // l5compat `carLocation()`) already call this; the browser
    // `navigator.geolocation` path is broken on the BYD WebView, so
    // without this handler they fall back to a hardcoded default city
    // even though the car has a valid GPS fix.
    _registerScopedHandler(
      controller,
      handlerName: 'location.read',
      callback: _handleLocationRead,
    );
    // ── native-capability families ─────────────────────────────────
    // Iterate every registered family and expose one JS handler per
    // op as `<familyId>.<op>`. This is what `bridge_family_registry.dart`
    // documents — the loop was missing prior to this patch, leaving
    // surface/pkg/display/gesture/cursor/boot orphaned even though
    // their families register at bootstrap.
    final registry = ref.read(bridgeFamilyRegistryProvider);
    for (final family in registry.families) {
      for (final op in family.handlers.keys) {
        final handlerName = '${family.familyId}.$op';
        controller.addJavaScriptHandler(
          handlerName: handlerName,
          callback: (args) => _handleFamilyCall(family.familyId, op, args),
        );
      }
    }
  }

  /// Dispatch a `<familyId>.<op>` JS call through [FamilyExecutor]. The
  /// SDK's `bridge.callFamily` posts `{params, idempotencyKey}` as the
  /// single arg; we unwrap both and forward.
  ///
  /// Returns the [AdminExecResult] envelope shape (`{success, data |
  /// error}`) so the SDK decoder is identical to the `car.*` and
  /// `_admin.exec` paths.
  Future<Map<String, Object?>> _handleFamilyCall(
    String familyId,
    String op,
    List<dynamic> args,
  ) async {
    final payload = _payload(args);
    final params =
        (payload['params'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    final idempotencyKey = payload['idempotencyKey'] as String?;

    final account = ref.read(localProfileProvider).value;
    final car = ref.read(currentCarProvider);
    final certHash =
        widget.app.certHash ??
        await ref
            .read(miniAppInstallStorageProvider)
            .certHashFor(widget.app.id) ??
        '';
    final session = AdminSession(
      userId: account?.id ?? '',
      deviceId: car?.deviceId ?? '',
      appId: widget.app.id,
      certHash: certHash,
      bundleSha256: widget.app.bundleSha256,
    );

    final family = ref.read(bridgeFamilyRegistryProvider).lookup(familyId);
    var ownerConfirmed = false;
    if (family?.handlers[op]?.requiresStepUp == true &&
        await _hasScope(family!.permissionIdFor(op))) {
      if (!mounted) return _error('permission_denied', 'Viewer closed');
      ownerConfirmed =
          await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('Allow $familyId.$op?'),
              content: Text(
                'This app requests control of touch input. Parameters: $params',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Allow once'),
                ),
              ],
            ),
          ) ??
          false;
    }
    final executor = await ref.read(familyExecutorProvider.future);
    final result = await executor.execute(
      familyId: familyId,
      op: op,
      args: params,
      session: session,
      idempotencyKey: idempotencyKey,
      ownerConfirmed: ownerConfirmed,
      eventPusher: _ViewerFamilyEventPusher(this),
    );
    final json = Map<String, dynamic>.from(result.toJson());
    _logBridgeFailure('family', '$familyId.$op', json);
    return json;
  }

  Future<Map<String, dynamic>> _handleGetContext(List<dynamic> args) async {
    final account = ref.read(localProfileProvider).value;
    final car = ref.read(currentCarProvider);
    final lang =
        ref.read(localeControllerProvider).value?.locale.languageCode ?? 'en';
    final brightness = Theme.of(context).brightness;
    return {
      'userId': account?.id ?? '',
      // VIN is the canonical car id app-wide (see
      // currentCarProvider); the mini-app receives the same identifier
      // the host uses, not a separate derived id.
      'activeCarId': await _hasScope('car.read') ? car?.deviceId ?? '' : '',
      'locale': lang,
      'isDark': brightness == Brightness.dark,
      'appVersion': widget.app.version,
      'appId': widget.app.id,
    };
  }

  /// `_admin.exec` bridge handler. The mini-app passes
  /// `{templateId, params, idempotencyKey}` and the dispatcher does
  /// everything: template lookup, consent check, cap validation,
  /// shell render, op execution, audit append. Capability tokens
  /// never enter this method — that's the Phase-9 host-owned-caps
  /// property.
  ///
  /// Non-privileged mini-apps reach this handler too, but the
  /// dispatcher's first gate (template lookup keyed by `cert_hash`)
  /// returns `unknown_template` for any cert hash that hasn't been
  /// granted privileged access. So calling `_admin.exec` from a
  /// regular mini-app is safe — it just always fails.
  Future<Map<String, dynamic>> _handleAdminExec(List<dynamic> args) async {
    if (args.isEmpty) return _error('bad_request', 'missing args');
    final payload = args.first;
    if (payload is! Map) {
      return _error('bad_request', 'args[0] must be an object');
    }

    final templateId = payload['templateId'] as String?;
    if (templateId == null || templateId.isEmpty) {
      return _error('bad_request', 'templateId required');
    }
    final idempotencyKey = payload['idempotencyKey'] as String?;
    if (idempotencyKey == null || idempotencyKey.isEmpty) {
      // SDK ≥ Phase-9 always sends one; rejecting null surfaces an
      // SDK/host version-drift early instead of silently disabling
      // retry protection.
      return _error('bad_request', 'idempotencyKey required');
    }
    final params = (payload['params'] as Map?)?.cast<String, Object?>();

    final account = ref.read(localProfileProvider).value;
    final car = ref.read(currentCarProvider);
    // Cert hash comes from the install record stamped by the
    // privileged-install orchestrator. Non-privileged mini-apps
    // never had it stamped, so this stays empty — the dispatcher's
    // first gate (template lookup keyed by cert_hash) returns
    // `unknown_template` and the call fails closed without ever
    // touching consent / cap / revocation logic.
    //
    // Reading via the storage helper rather than `widget.app.certHash`
    // catches the case where a privileged install completed *after*
    // this viewer was constructed (rare — install is gated behind
    // the catalog UI, not the launched-app UI — but keeps the read
    // authoritative).
    final certHash =
        widget.app.certHash ??
        await ref
            .read(miniAppInstallStorageProvider)
            .certHashFor(widget.app.id) ??
        '';
    final session = AdminSession(
      userId: account?.id ?? '',
      deviceId: car?.deviceId ?? '',
      appId: widget.app.id,
      certHash: certHash,
      bundleSha256: widget.app.bundleSha256,
    );

    final dispatcher = await ref.read(adminDispatcherProvider.future);
    final result = await dispatcher.exec(
      templateId: templateId,
      params: params,
      idempotencyKey: idempotencyKey,
      currentSession: session,
    );
    final json = Map<String, dynamic>.from(result.toJson());
    _logBridgeFailure('_admin.exec', templateId, json);
    return json;
  }

  // ── car.* handlers ──────────────────────────────────────────────
  //
  // Every car.* handler is a thin shim that:
  //   1. Extracts the args map from `args[0]` (or {} if absent).
  //   2. Forwards to [CarBridgeService].
  //   3. Returns the service's response unchanged.
  //
  // The service handles throttling, name-cap, audit, encoding —
  // none of that logic lives here.

  Future<Map<String, Object?>> _handleCarList(List<dynamic> args) async {
    final payload = _payload(args);
    return _carBridge.list(
      category: payload['category'] as String?,
      threeDOnly: (payload['threeDOnly'] as bool?) ?? false,
    );
  }

  Future<Map<String, Object?>> _handleCarRead(List<dynamic> args) async {
    return _carBridge.read(_namesFromArgs(args));
  }

  Future<Map<String, Object?>> _handleCarSubscribe(List<dynamic> args) async {
    final names = _namesFromArgs(args);
    final id = const Uuid().v4();
    final response = _carBridge.subscribe(
      id,
      names,
      (encodedJson) => _pushSignal(id, encodedJson),
      viewerId: _viewerId,
    );
    // Only track the id if the service accepted the subscription —
    // an error envelope (no `subscriptionId` key) means the service
    // never registered it, so we mustn't try to drain it on dispose.
    if (response['subscriptionId'] == id) {
      _subscriptionIds.add(id);
    }
    return response;
  }

  Future<Map<String, Object?>> _handleCarUnsubscribe(List<dynamic> args) async {
    final payload = _payload(args);
    final id = payload['subscriptionId'] as String?;
    if (id == null || id.isEmpty) {
      return _error(
        'bad_request',
        'unsubscribe payload missing subscriptionId',
      );
    }
    _carBridge.unsubscribe(id);
    _subscriptionIds.remove(id);
    return {'subscriptionId': id};
  }

  Future<Map<String, Object?>> _handleCarCommand(List<dynamic> args) async {
    final payload = _payload(args);
    final actionId = payload['actionId'] as String?;
    if (actionId == null || actionId.isEmpty) {
      return _error('bad_request', 'command payload missing actionId');
    }
    final cmdArgs =
        (payload['args'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    return _carBridge.command(actionId: actionId, args: cmdArgs);
  }

  Future<Map<String, Object?>> _handleCarIdentity(List<dynamic> args) async {
    return _carBridge.identity();
  }

  /// `location.read` — flat payload `{ lat, lng, accuracyM?, at? }`.
  /// Sourced from [LocationService.current] (handles its own runtime
  /// permission). Key names match what `weather-ahead` (its path-2
  /// `location.read`) and l5compat `carLocation()` already read, so
  /// they light up with no mini-app change. Returns the standard
  /// error envelope when there's no fix (permission denied / no GPS)
  /// so callers fall through to their next source instead of
  /// surfacing a wrong default.
  Future<Map<String, Object?>> _handleLocationRead(List<dynamic> args) async {
    final fix = await ref.read(locationServiceProvider).current();
    if (fix == null) {
      return _error(
        'location_unavailable',
        'no location fix (permission denied or no GPS signal)',
      );
    }
    return {
      'lat': fix.latitude,
      'lng': fix.longitude,
      'accuracyM': fix.accuracyM,
      'at': fix.at?.toIso8601String(),
    };
  }

  Future<Map<String, Object?>> _handleCarAsset(List<dynamic> args) async {
    final payload = _payload(args);
    final path = payload['path'] as String?;
    if (path == null || path.isEmpty) {
      return _error('bad_request', 'asset payload missing path');
    }
    return _carBridge.asset(path);
  }

  Future<Map<String, Object?>> _handleCarConnectionSubscribe(
    List<dynamic> args,
  ) async {
    final id = const Uuid().v4();
    _carBridge.connectionSubscribe(id, (state) => _pushConnection(id, state));
    _connectionSubscriptionIds.add(id);
    return {'subscriptionId': id};
  }

  Future<Map<String, Object?>> _handleCarConnectionUnsubscribe(
    List<dynamic> args,
  ) async {
    final payload = _payload(args);
    final id = payload['subscriptionId'] as String?;
    if (id == null || id.isEmpty) {
      return _error(
        'bad_request',
        'unsubscribe payload missing subscriptionId',
      );
    }
    _carBridge.connectionUnsubscribe(id);
    _connectionSubscriptionIds.remove(id);
    return {'subscriptionId': id};
  }

  /// Extract the first arg as a map, falling back to an empty map.
  Map<String, Object?> _payload(List<dynamic> args) {
    if (args.isEmpty) return const <String, Object?>{};
    final first = args.first;
    if (first is! Map) return const <String, Object?>{};
    return first.cast<String, Object?>();
  }

  /// Decode the `names` list from `args[0]`. Tolerant of missing /
  /// malformed payloads — the service rejects the empty list cleanly.
  List<String> _namesFromArgs(List<dynamic> args) {
    final payload = _payload(args);
    final raw = payload['names'];
    if (raw is! List) return const <String>[];
    return raw.map((e) => e.toString()).toList(growable: false);
  }

  /// Push a signal event into the WebView's `__i99dashEvents` bus.
  /// The SDK demuxes by `subscriptionId` (the service encodes the
  /// public catalog name in `payload.name`); the host just dispatches
  /// on the single `car.signal` channel.
  ///
  /// `encodedJson` is the already-encoded JSON payload from the
  /// service — keeping encoding off the change-frame hot path is part
  /// of the service's throttle contract.
  void _pushSignal(String subscriptionId, String encodedJson) {
    final controller = _controller;
    if (controller == null || _disposed) return;
    // Wrap the service-encoded payload so the SDK side can correlate
    // by subscriptionId (mini-apps with multiple subs all share one
    // `__i99dashEvents` bus).
    final envelope =
        '{"subscriptionId":${jsonEncode(subscriptionId)},"data":$encodedJson}';
    unawaited(_dispatchToPage(controller, 'car.signal', envelope));
  }

  /// Push a connection-state change. The service emits the bare
  /// state string (`connected | disconnected | degraded | unknown`);
  /// we wrap it with the subscriptionId so the SDK can route the
  /// event to the right listener.
  void _pushConnection(String subscriptionId, String state) {
    final controller = _controller;
    if (controller == null || _disposed) return;
    final envelope =
        '{"subscriptionId":${jsonEncode(subscriptionId)},"state":${jsonEncode(state)}}';
    unawaited(_dispatchToPage(controller, 'car.connection', envelope));
  }

  /// Constant prefix shared by every car.* dispatch — stitched once
  /// at class-load time so the hot push path only concatenates the
  /// dynamic channel + payload, not the entire JS expression.
  static const String _kDispatchJsPrefix =
      'window.__i99dashEvents && window.__i99dashEvents.dispatch("';

  Future<void> _dispatchToPage(
    InAppWebViewController controller,
    String channel,
    String payloadJson,
  ) async {
    final family = ref
        .read(bridgeFamilyRegistryProvider)
        .lookup(channel.split('.').first);
    final scope =
        directBridgeScope(channel) ??
        (family?.permissionIds.length == 1
            ? family!.permissionIds.first
            : null);
    if (_disposed || scope == null || !await _hasScope(scope)) return;
    // Build the JS expression. The SDK installed the polyfill on its
    // own; if it isn't present the page just doesn't have a listener
    // to dispatch to — silent no-op rather than an error.
    final js = '$_kDispatchJsPrefix$channel", $payloadJson)';
    // Fire-and-forget — an error here means the page is already torn
    // down or evaluation failed, both of which are out of band for
    // the bridge handler that returned its success envelope already.
    // ignore: discarded_futures
    await controller.evaluateJavascript(source: js);
  }

  static Map<String, dynamic> _error(String code, String message) => {
    'success': false,
    'error': {'code': code, 'message': message},
  };

  void _logBridgeFailure(
    String op,
    String? subjectId,
    Map<String, dynamic> result,
  ) {}
}

/// Adapter from [FamilyEventPusher] to the viewer's
/// `window.__i99dashEvents.dispatch(...)` JS hop. Stream-cadence
/// handlers (display.subscribe, future surface.subscribe, …) use
/// this to forward native events into the mini-app's JS world.
class _ViewerFamilyEventPusher implements FamilyEventPusher {
  _ViewerFamilyEventPusher(this._viewer);

  final _MiniAppViewerState _viewer;

  @override
  void pushEvent(String channel, Map<String, Object?> payload) {
    final controller = _viewer._controller;
    if (controller == null || _viewer._disposed) return;
    unawaited(
      _viewer._dispatchToPage(controller, channel, jsonEncode(payload)),
    );
  }
}

/// Runs before any page script so `@ilink/sdk` can find the host
/// bridge under the branded `window.__i99dashHost` name instead of
/// the plugin's transport-level global. Mini-app authors never
/// touch this directly — the SDK's `MiniAppClient.fromWindow()`
/// reads it. The alias is additive: legacy code paths that still
/// reach for the transport name continue to work.
///
/// Exposed at top level (not as a private method on the state) so a
/// unit test can assert the script shape without constructing the
/// widget through a platform channel. The `InAppWebView` widget
/// accepts `initialUserScripts` in its constructor but does not
/// re-expose it as a getter, so poking the widget directly isn't an
/// option.
UnmodifiableListView<UserScript> brandedGlobalAliasUserScripts({
  List<Map<String, dynamic>> adminCatalog = const [],
  List<String> networkOrigins = const [],
  bool networkEnabled = false,
}) {
  // Encoded with ``json.encode`` (not string interpolation) so any
  // payload — including future templates whose param-schemas contain
  // backslashes, quotes, or non-ASCII text — round-trips through the
  // injected ``window.__i99dashAdminCatalog`` global as valid JSON
  // without manual escaping. Empty list ``[]`` is the safe default —
  // mini-apps that pull the SDK's ``snapshotFromList(window.__i99dashAdminCatalog ?? [])``
  // pattern degrade gracefully while the host is loading the local catalog.
  final catalogJson = jsonEncode(adminCatalog);
  // jsonEncode produces a safe, fully-escaped JS string literal for the CSP.
  final cspJson = jsonEncode(
    networkEnabled
        ? buildMiniAppCsp(networkOrigins)
        : "default-src 'self' file: data: blob:; script-src 'self' file: 'unsafe-inline' 'unsafe-eval'; "
              "style-src 'self' file: 'unsafe-inline'; connect-src 'self' file:; "
              "object-src 'none'; base-uri 'self'; form-action 'none'; worker-src 'none'",
  );
  final offlineScript = networkEnabled
      ? ''
      : '(function(){var deny=function(){throw new Error("Enable downloads in Optional Services for mini-app network access");};'
            '["WebSocket","EventSource","Worker","SharedWorker"].forEach(function(k){'
            'try{Object.defineProperty(window,k,{value:deny,writable:false,configurable:false});}catch(e){}});'
            'try{if(navigator.serviceWorker){navigator.serviceWorker.register=deny;}}catch(e){}'
            '})();';
  return UnmodifiableListView<UserScript>([
    // ── egress hardening (runs FIRST, in EVERY frame) ──────────────────
    // Two things CSP can't do reliably on the frozen WebView, done in JS
    // at document-start (which genuinely runs before any page script):
    //   1. Neuter WebRTC — RTCPeerConnection/STUN/data-channel egress
    //      bypasses CSP `connect-src` entirely and is invisible to the
    //      request interceptor. Delete the constructors so `new
    //      RTCPeerConnection()` throws.
    //   2. Inject the per-app CSP as a <meta> as defense-in-depth. CSP is
    //      NOT the enforced boundary here (a `<meta>` policy is racy on old
    //      Chromium) — the `shouldInterceptRequest` gate is. The meta adds
    //      coverage for channels the gate doesn't see on cars where it
    //      parses. `forMainFrameOnly: false` so same-bundle child frames
    //      are hardened too.
    UserScript(
      source:
          '${offlineScript}try{'
          'var m=document.createElement("meta");'
          'm.httpEquiv="Content-Security-Policy";'
          'm.content=$cspJson;'
          '(document.head||document.documentElement).appendChild(m);'
          '}catch(e){}'
          'try{'
          'var R=function(){throw new Error("WebRTC disabled in mini-app sandbox");};'
          'window.RTCPeerConnection=R;'
          'window.webkitRTCPeerConnection=R;'
          'window.RTCDataChannel=undefined;'
          'if(navigator.mediaDevices){navigator.mediaDevices.getUserMedia=function(){return Promise.reject(new Error("disabled"));};}'
          '}catch(e){}',
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      forMainFrameOnly: false,
    ),
    UserScript(
      // LAZY FORWARDER (not a value-capture alias). The previous form,
      // `window.__i99dashHost = window.flutter_inappwebview`, captured the
      // plugin global BY VALUE at AT_DOCUMENT_START — but on Di5.0 /
      // Chromium-95 the plugin hasn't created `window.flutter_inappwebview`
      // (nor its `callHandler`) that early, so `__i99dashHost` was pinned to
      // `undefined` forever AND the page's synchronous bootstrap
      // (`MiniAppClient.fromWindow()`) ran before the plugin bridge came up
      // → "host bridge unavailable" and a stuck mini-app. (Di5.1 ships a
      // newer WebView where the bridge is ready in time, so it never bit
      // there.) Here `__i99dashHost.callHandler` is ALWAYS a function at
      // document-start (so `fromWindow()` resolves immediately), and the
      // real native call is resolved LAZILY at call-time — forwarding to
      // `flutter_inappwebview.callHandler`, polling briefly if it isn't up
      // yet. No-op behaviourally on Di5.1.
      source:
          '(function(){'
          'function call(){'
          'var f=window.flutter_inappwebview;'
          'if(f&&typeof f.callHandler==="function"){return f.callHandler.apply(f,arguments);}'
          'var a=arguments;'
          'return new Promise(function(res,rej){'
          'var n=0,t=setInterval(function(){'
          'var g=window.flutter_inappwebview;'
          'if(g&&typeof g.callHandler==="function"){clearInterval(t);try{g.callHandler.apply(g,a).then(res,rej);}catch(e){rej(e);}}'
          'else if(++n>150){clearInterval(t);rej(new Error("ilink host bridge never became ready"));}'
          '},100);});'
          '}'
          'window.__i99dashHost={callHandler:call};'
          'var geo={getCurrentPosition:function(ok,fail){'
          'call("location.read",{}).then(function(p){'
          'if(!p||typeof p.lat!=="number"||typeof p.lng!=="number"){'
          'if(fail)fail({code:p&&p.error&&p.error.code==="permission_denied"?1:2,message:"Location unavailable or permission denied"});return;}'
          'ok({coords:{latitude:p.lat,longitude:p.lng,accuracy:p.accuracyM||0,altitude:null,altitudeAccuracy:null,heading:null,speed:null},timestamp:p.at?Date.parse(p.at):Date.now()});'
          '},function(){if(fail)fail({code:2,message:"Location unavailable"});});},'
          'watchPosition:function(ok,fail){geo.getCurrentPosition(ok,fail);return setInterval(function(){geo.getCurrentPosition(ok,fail);},5000);},'
          'clearWatch:function(id){clearInterval(id);}};'
          'try{Object.defineProperty(navigator,"geolocation",{value:geo,writable:false,configurable:false});}catch(e){}'
          'window.__i99dashAdminCatalog = $catalogJson;'
          '})();',
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      // `allowedOriginRules: null` (default) → allow-listed origin
      // control already runs at `shouldOverrideUrlLoading` + the
      // initial-URL check; scoping here would be a second rule-set
      // to keep in sync with no safety win.
      forMainFrameOnly: true,
    ),
  ]);
}

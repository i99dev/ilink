import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ilink/features/mini_apps/presentation/mini_app_viewer.dart';

/// Shape-only unit test for the user-scripts the viewer installs on the
/// WebView: an egress-hardening script (per-app CSP + WebRTC neuter, runs in
/// every frame) followed by the branded-global alias script (main frame).
///
/// The `InAppWebView` widget takes `initialUserScripts` in its constructor but
/// does not re-expose it as a public getter, so inspecting the widget directly
/// isn't an option. Instead the viewer exposes `brandedGlobalAliasUserScripts()`
/// at top level and `_buildWebView` passes its result to the constructor.
void main() {
  group('brandedGlobalAliasUserScripts', () {
    test('installs the hardening script then the alias script', () {
      final scripts = brandedGlobalAliasUserScripts().toList();
      expect(scripts, hasLength(2));
    });

    test('all scripts run at document start (before any page script)', () {
      for (final s in brandedGlobalAliasUserScripts()) {
        expect(s.injectionTime, UserScriptInjectionTime.AT_DOCUMENT_START);
      }
    });

    group('hardening script (first)', () {
      UserScript first() => brandedGlobalAliasUserScripts().first;

      test('runs in every frame (not main-frame-only)', () {
        expect(first().forMainFrameOnly, isFalse);
      });

      test('neuters the WebRTC constructors', () {
        expect(first().source, contains('window.RTCPeerConnection'));
        expect(first().source, contains('window.webkitRTCPeerConnection'));
      });

      test('injects a per-app Content-Security-Policy meta', () {
        final src = brandedGlobalAliasUserScripts(
          networkEnabled: true,
          networkOrigins: const ['https://api.aladhan.com'],
        ).first.source;
        expect(src, contains('Content-Security-Policy'));
        // The declared origin must be carried into the policy string.
        expect(src, contains('https://api.aladhan.com'));
        // Retired bundle hosting is never an allowed origin.
        expect(src, isNot(contains('https://miniapps.i99dash.app')));
      });
    });

    group('alias script (last)', () {
      UserScript alias() => brandedGlobalAliasUserScripts().last;

      test('exposes a lazy callHandler forwarder under the branded name', () {
        final src = alias().source;
        // `__i99dashHost.callHandler` must ALWAYS be a function at
        // document-start so `MiniAppClient.fromWindow()` resolves even on
        // Di5.0/Chromium-95 where the plugin global comes up late — NOT a
        // by-value alias of `window.flutter_inappwebview` (which is
        // `undefined` that early).
        expect(src, contains('window.__i99dashHost={callHandler:call}'));
        // …and the forwarder routes to the plugin global at call-time.
        expect(src, contains('window.flutter_inappwebview'));
        expect(src, contains('callHandler.apply'));
        // Must NOT be the brittle value-capture form.
        expect(
          src,
          isNot(
            contains('window.__i99dashHost = window.flutter_inappwebview;'),
          ),
        );
      });

      test('injects the admin catalog as JSON (default empty)', () {
        expect(alias().source, contains('window.__i99dashAdminCatalog = []'));
      });

      test('admin catalog payload round-trips arbitrary entries as JSON', () {
        final src = brandedGlobalAliasUserScripts(
          adminCatalog: const [
            {'id': 'foo', 'label': 'with "quotes" and \\ backslash'},
          ],
        ).last.source;
        expect(
          src,
          contains(
            r'window.__i99dashAdminCatalog = '
            r'[{"id":"foo","label":"with \"quotes\" and \\ backslash"}];',
          ),
        );
      });

      test('is scoped to the main frame only', () {
        expect(alias().forMainFrameOnly, isTrue);
      });
    });
  });
}

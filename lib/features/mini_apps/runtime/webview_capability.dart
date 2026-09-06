/// Measured WebView capability for the active car — the real Gate-B fact.
///
/// Replaces the old `dilinkFamily`-proxied "modern WebView" guess (Di5.0
/// ⇒ always incompatible) with the ACTUAL installed-WebView Chromium
/// major, read once per session via
/// `InAppWebViewController.getCurrentWebViewPackage()`. The proxy was
/// wrong in both directions: Di5.0 trims (Song PLUS, L5) ship Chromium
/// **95**, which runs the modern ES-module mini-app bundles fine — the
/// proxy was silently rejecting supportable cars. Measuring is correct
/// for every car and is the single upstream of the
/// `CompatTarget.modernWebview` fact (see [mini_app_compat_target]).
///
/// Pure helpers here are unit-tested (`webview_capability_test.dart`);
/// the provider is the only impure part (one async platform read).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Conservative ES-module floor. Chromium ≥ 85 reliably runs the modern
/// ES the shipped mini-app bundles use (dynamic `import()`, import maps,
/// modern syntax). 85 (not 61) avoids false-positives on the 61–79
/// range; the measured Di5.0 fleet is 95, comfortably above. Matches the
/// car-profiler's `supportsEsModules` floor.
const int kEsModuleChromiumFloor = 85;

/// Parse the Chromium **major** from a WebView `versionName`
/// (e.g. `"95.0.4638.74"` → `95`). Returns null for null/garbage input.
/// Pure.
int? chromiumMajorFromVersionName(String? versionName) {
  final head = versionName?.trim().split('.').first;
  if (head == null || head.isEmpty) return null;
  return int.tryParse(head);
}

/// Map a measured Chromium major to the `modernWebview` car fact:
/// `>= kEsModuleChromiumFloor` ⇒ `true` (ES-module capable), below ⇒
/// `false`, unknown (`null`) ⇒ `null` so the caller can fall back to the
/// generation proxy / fail closed rather than assume modern. Pure.
bool? modernWebviewFromChromiumMajor(int? major) =>
    major == null ? null : major >= kEsModuleChromiumFloor;

/// The installed system WebView's Chromium major for the active device,
/// measured once and cached for the session (the WebView provider can't
/// change mid-session). `null` when unmeasurable — non-Android, the read
/// failed, or the provider isn't resolvable yet — so callers fall back
/// to the conservative generation proxy rather than assume modern.
final webviewChromiumMajorProvider = FutureProvider<int?>((ref) async {
  if (defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    final pkg = await InAppWebViewController.getCurrentWebViewPackage();
    return chromiumMajorFromVersionName(pkg?.versionName);
  } catch (_) {
    // Plugin not ready / platform without the API → unmeasurable.
    return null;
  }
});

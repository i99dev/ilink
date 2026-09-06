/// User-facing translation of mini-app install failures.
///
/// Every install failure raised by the privileged-install orchestrator
/// (manifest fetch, cert envelope, signature verify, session cap, etc.)
/// or by the regular bundle store maps to a friendly explanation here.
/// Centralised so every Install button across the screen produces the
/// same wording for the same failure mode.
library;

import 'package:flutter/material.dart';

import '../state/mini_app_install_gate.dart';

/// Pretty-print [error] for a SnackBar.
///
/// Returns a short headline + an optional details line. Headline is
/// the user-friendly action ("Install failed"),
/// details is the underlying exception message verbatim — we keep it
/// because the behind-the-scenes signal is the user's main ask, and
/// they explicitly want to *see* what's failing.
({String headline, String? details}) describeInstallError(Object error) {
  return (headline: 'Install failed', details: error.toString());
}

/// Show a SnackBar describing [error]. Caller-friendly — pass the raw
/// caught exception and the function does the prettification.
void showInstallErrorSnack(BuildContext context, Object error) {
  final desc = describeInstallError(error);
  _showSnack(context, desc.headline, desc.details);
}

/// Show a SnackBar describing the gate's structured [outcome]. Use this
/// from every caller that drives [MiniAppInstallGate]; success silently
/// no-ops so callers can `await gate.install(...)` and only handle the
/// surface UX (snackbar, dismiss, etc.). Returns true when [outcome]
/// represents a failure the user should see.
bool showInstallOutcomeSnack(BuildContext context, InstallOutcome outcome) {
  switch (outcome) {
    case InstallOk():
      return false;
    case InstallUnknownApp(:final appId):
      _showSnack(
        context,
        'Mini-app not available',
        'The catalog row for "$appId" is no longer available. Pull to refresh.',
      );
      return true;
    case InstallFailed(:final error):
      showInstallErrorSnack(context, error);
      return true;
  }
}

void _showSnack(BuildContext context, String headline, String? details) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 7),
      behavior: SnackBarBehavior.floating,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(headline, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (details != null) ...[
            const SizedBox(height: 4),
            Text(details, style: const TextStyle(fontSize: 12, height: 1.3)),
          ],
        ],
      ),
    ),
  );
}

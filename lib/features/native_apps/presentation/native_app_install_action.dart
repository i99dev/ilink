import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../kernel/i18n/generated/app_localizations.dart';
import '../domain/native_app.dart';
import '../state/native_app_store_controller.dart';

/// Install / Update / Installed button for one native-app store row.
///
/// The selected local file is copied and checked before Android asks for
/// installation consent. Failures surface in a SnackBar.
class NativeAppInstallButton extends ConsumerStatefulWidget {
  const NativeAppInstallButton({
    super.key,
    required this.app,
    required this.lang,
    this.compact = false,
  });

  final NativeApp app;
  final String lang;
  final bool compact;

  @override
  ConsumerState<NativeAppInstallButton> createState() =>
      _NativeAppInstallButtonState();
}

class _NativeAppInstallButtonState
    extends ConsumerState<NativeAppInstallButton> {
  bool _busy = false;

  Future<void> _onInstall() async {
    setState(() => _busy = true);
    final selected = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['apk'],
    );
    final path = selected?.files.single.path;
    if (path == null) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    final result = await ref
        .read(nativeAppStoreProvider.notifier)
        .importApk(path, expectedPackage: widget.app.packageId);
    if (!mounted) return;
    setState(() => _busy = false);
    showNativeInstallResult(context, widget.app, result, widget.lang);
  }

  Future<void> _onUninstall() async {
    final t = S.of(context);
    final name = widget.app.localizedName(widget.lang);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(t.nativeAppsUninstallConfirm(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.miniAppsUninstall),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final result = await ref
        .read(nativeAppStoreProvider.notifier)
        .uninstall(widget.app, label: name);
    if (!mounted) return;
    setState(() => _busy = false);
    showNativeInstallResult(context, widget.app, result, widget.lang);
  }

  @override
  Widget build(BuildContext context) {
    final t = S.of(context);
    final app = widget.app;
    final isCurrent = app.isInstalled && !app.hasUpdate;
    final compact = widget.compact;

    final padding = compact
        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6)
        : null;

    final spinner = _busy
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : null;

    // Installed and current → offer Uninstall (the home grid uses the same
    // silent `pm uninstall`). Update available → Update. Otherwise → Install.
    if (isCurrent) {
      return OutlinedButton(
        onPressed: _busy ? null : _onUninstall,
        style: OutlinedButton.styleFrom(
          visualDensity: compact ? VisualDensity.compact : null,
          padding: padding,
        ),
        child: spinner ?? Text(t.miniAppsUninstall),
      );
    }

    final label = app.hasUpdate ? t.nativeAppsUpdate : t.nativeAppsInstall;
    return FilledButton(
      onPressed: _busy ? null : _onInstall,
      style: FilledButton.styleFrom(
        visualDensity: compact ? VisualDensity.compact : null,
        padding: padding,
      ),
      child: spinner ?? Text(label),
    );
  }
}

/// Map a [NativeStoreInstallResult] to a localized SnackBar. Centralised so
/// the card and the details sheet render identical feedback.
void showNativeInstallResult(
  BuildContext context,
  NativeApp app,
  NativeStoreInstallResult result,
  String lang,
) {
  final t = S.of(context);
  final name = app.localizedName(lang);
  final message = switch (result.kind) {
    NativeStoreInstallKind.installing => t.nativeAppsInstalling(name),
    NativeStoreInstallKind.error => t.nativeAppsInstallError(
      name,
      result.message ?? '',
    ),
    NativeStoreInstallKind.uninstalled => t.nativeAppsUninstalled(name),
    NativeStoreInstallKind.uninstallFailed => t.nativeAppsUninstallFailed(name),
  };
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

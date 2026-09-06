/// "App info" card — version + buildNumber, package id and app name.
///
/// Pulls from `package_info_plus` once per app session via a
/// [FutureProvider] (cheap; the underlying platform call is also
/// cached). Lives in its own file so the Diagnostics page only carries
/// this provider definition transitively.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../../../kernel/i18n/generated/app_localizations.dart';
import 'diagnostics_card.dart';

final _appInfoProvider = FutureProvider<PackageInfo>((_) async {
  return PackageInfo.fromPlatform();
});

class AppInfoCard extends ConsumerWidget {
  const AppInfoCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    final info = ref.watch(_appInfoProvider);
    return DiagnosticsCard(
      title: t.diagnosticsAppCard,
      child: info.when(
        data: (p) => DiagnosticsKvList(
          items: {
            t.diagnosticsKvVersion: '${p.version}+${p.buildNumber}',
            t.diagnosticsKvPackage: p.packageName,
            t.diagnosticsKvName: p.appName,
          },
        ),
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: LinearProgressIndicator(),
        ),
        error: (e, _) => DiagnosticsErrorText(message: e.toString()),
      ),
    );
  }
}

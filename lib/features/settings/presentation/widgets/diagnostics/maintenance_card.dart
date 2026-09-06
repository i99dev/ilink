/// Maintenance card — operator-grade actions that don't fit any single
/// feature. The radio-refresh / radio-cache-clear rows were retired when
/// the remote M3U catalogue was replaced by bundled demos + user-imported
/// playlists (nothing to refresh or cache); favourites and user playlists
/// are managed from the Radio screen itself.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../kernel/i18n/generated/app_localizations.dart';
import 'diagnostics_card.dart';

class MaintenanceCard extends ConsumerWidget {
  const MaintenanceCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = S.of(context);
    return DiagnosticsCard(
      title: t.diagnosticsMaintenanceCard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DiagnosticsActionRow(
            icon: Icons.file_download_outlined,
            label: t.diagnosticsExportLogs,
            description: t.diagnosticsExportLogsDesc,
            onPressed: null,
          ),
        ],
      ),
    );
  }
}

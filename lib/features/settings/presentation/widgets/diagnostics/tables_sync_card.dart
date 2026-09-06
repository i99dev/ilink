library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ilink/features/_car_domain/safety/security_bridge.dart';
import 'package:ilink/sdk/brands/byd/byd_status_labels.dart';
import 'package:ilink/sdk/car.dart';

import 'diagnostics_card.dart';

typedef _V2Status = ({String? carTable, String? miniApp});

/// Existing local cache status. Tables ship in the application assets.
final _v2StatusProvider = FutureProvider.autoDispose<_V2Status>((ref) async {
  final bridge = ref.read(securityBridgeProvider);
  return (
    carTable: await bridge.v2TableEtag('car_table'),
    miniApp: await bridge.v2TableEtag('mini_app_table'),
  );
});

class TablesSyncCard extends ConsumerStatefulWidget {
  const TablesSyncCard({super.key});

  @override
  ConsumerState<TablesSyncCard> createState() => _TablesSyncCardState();
}

class _TablesSyncCardState extends ConsumerState<TablesSyncCard> {
  bool _scanning = false;
  Map<String, String>? _scanResult;
  String? _scanError;

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _scanError = null;
    });
    final out = <String, String>{};
    try {
      final client = ref.read(carClientProvider);
      // Daemon push/poll counters — keep only the numeric/bool entries
      // so the readout stays "numbers only".
      final stats = await client.registryStats();
      for (final e in stats.entries) {
        final v = e.value;
        if (v is num || v is bool) out[e.key] = '$v';
      }
      // Live field count vs the known catalog size — same signal as the
      // gate probe card's "X live / Y known".
      final live = (await client.liveFeatures()).length;
      final known = bydStatusLabelToCatalog.values.toSet().length;
      out['live / known'] = '$live / $known';
    } catch (e) {
      if (mounted) setState(() => _scanError = '$e');
    }
    if (!mounted) return;
    setState(() {
      _scanResult = out.isEmpty ? null : out;
      _scanning = false;
    });
  }

  static String _etagLabel(String? etag) {
    if (etag == null || etag.isEmpty) return 'Bundled local table';
    return etag.length <= 12 ? etag : '${etag.substring(0, 12)}…';
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(_v2StatusProvider);
    final items = <String, String>{
      'Car table': status.maybeWhen(
        data: (s) => _etagLabel(s.carTable),
        orElse: () => '…',
      ),
      'Mini-app table': status.maybeWhen(
        data: (s) => _etagLabel(s.miniApp),
        orElse: () => '…',
      ),
    };

    return DiagnosticsCard(
      title: 'Local command tables',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DiagnosticsKvList(items: items),
          const SizedBox(height: 12),
          DiagnosticsActionRow(
            icon: Icons.radar,
            label: _scanning ? 'Scanning…' : 'Scan',
            description: 'Daemon counters + live/known fields',
            onPressed: _scan,
          ),
          if (_scanError != null) ...[
            const SizedBox(height: 10),
            DiagnosticsErrorText(message: _scanError!),
          ],
          if (_scanResult != null) ...[
            const SizedBox(height: 10),
            DiagnosticsKvList(items: _scanResult!),
          ],
        ],
      ),
    );
  }
}

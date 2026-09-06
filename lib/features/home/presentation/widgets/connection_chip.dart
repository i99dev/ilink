/// Tiny status chip that surfaces `CarClient.connectionState`. Only
/// renders when the daemon isn't `connected` — happy-path is invisible
/// so the dashboard stays clean.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../sdk/car/client.dart';

class ConnectionChip extends ConsumerStatefulWidget {
  const ConnectionChip({super.key});

  @override
  ConsumerState<ConnectionChip> createState() => _ConnectionChipState();
}

class _ConnectionChipState extends ConsumerState<ConnectionChip> {
  late DaemonState _state;
  late final Stream<DaemonState> _stream;

  @override
  void initState() {
    super.initState();
    final client = ref.read(carClientProvider);
    _state = client.currentConnectionState;
    _stream = client.connectionState();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DaemonState>(
      stream: _stream,
      initialData: _state,
      builder: (context, snap) {
        final state = snap.data ?? DaemonState.connected;
        if (state == DaemonState.connected) return const SizedBox.shrink();
        final amber = state == DaemonState.reconnecting;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: (amber ? const Color(0xFFD9A227) : const Color(0xFFD93939))
                .withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                amber ? Icons.sync_problem : Icons.cloud_off,
                size: 14,
                color: amber
                    ? const Color(0xFFD9A227)
                    : const Color(0xFFD93939),
              ),
              const SizedBox(width: 6),
              Text(
                amber ? 'reconnecting' : 'no daemon',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: amber
                      ? const Color(0xFFD9A227)
                      : const Color(0xFFD93939),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

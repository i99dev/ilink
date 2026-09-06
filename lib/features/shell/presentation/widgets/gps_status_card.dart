/// Live GPS diagnostic tile — shows the LocationService's stream
/// state in real time so we can verify the always-on keepalive (the
/// one we restored after the map screen went away in Apr 2026 and
/// re-routed via ``forceLocationManager: true`` to bypass FusedLocationProvider's
/// broken-on-BYD-HU path) is actually populating the cache.
///
/// What's surfaced:
///   * permission state (granted / denied / unavailable)
///   * latest fix (lat, lng, accuracy)
///   * age of that fix (re-renders every second so a stale cache is
///     visually obvious — the header turns amber/red as the value
///     ages out)
///   * a "force fresh fix" button that calls
///     [LocationService.freshFix] and surfaces the round-trip
///
/// Lives under the Dev screen so non-dev builds don't pay the
/// always-on rebuild cost (the age ticker rebuilds once a second).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/ui/theme/colors.dart';
import '../../../../platform/location/location_service.dart';

class GpsStatusCard extends ConsumerStatefulWidget {
  const GpsStatusCard({super.key});

  @override
  ConsumerState<GpsStatusCard> createState() => _GpsStatusCardState();
}

class _GpsStatusCardState extends ConsumerState<GpsStatusCard> {
  Timer? _ageTicker;
  LocationFix? _refreshResult;
  String? _refreshError;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    // Re-render every second so the "age" line counts up live and
    // the colour coding flips amber → red as the cache goes stale.
    // Cheap: only this widget rebuilds, not the surrounding screen.
    _ageTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ageTicker?.cancel();
    super.dispose();
  }

  Future<void> _forceFresh() async {
    setState(() {
      _refreshing = true;
      _refreshError = null;
    });
    try {
      final fix = await ref
          .read(locationServiceProvider)
          .freshFix(
            // Force a real GNSS poll — never accept the in-process cache.
            maxCacheAge: Duration.zero,
            timeout: const Duration(seconds: 8),
          );
      if (!mounted) return;
      setState(() {
        _refreshResult = fix;
        _refreshError = fix == null
            ? 'freshFix returned null (timeout / no permission / chip cold)'
            : null;
        _refreshing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _refreshError = '$e';
        _refreshing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final stream = ref.watch(currentLocationProvider);
    final fix = stream.value;
    final age = fix?.at == null ? null : DateTime.now().difference(fix!.at!);
    final ageColor = _ageColor(age);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gps_fixed_rounded, color: ageColor, size: 18),
              const SizedBox(width: 8),
              Text(
                'GPS keepalive',
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
              const Spacer(),
              _AgeChip(age: age, color: ageColor),
            ],
          ),
          const SizedBox(height: 10),
          if (stream.isLoading && fix == null)
            _row(cs, 'state', 'subscribing — first fix not in yet')
          else if (stream.hasError)
            _row(cs, 'state', 'stream error: ${stream.error}')
          else if (fix == null)
            _row(
              cs,
              'state',
              'no fix yet — chip warming, permission denied, or sky obstructed',
            )
          else ...[
            _row(
              cs,
              'lat / lng',
              '${fix.latitude.toStringAsFixed(6)}, '
                  '${fix.longitude.toStringAsFixed(6)}',
            ),
            if (fix.accuracyM != null)
              _row(cs, 'accuracy', '±${fix.accuracyM!.toStringAsFixed(0)} m'),
            if (fix.at != null)
              _row(
                cs,
                'fix at',
                fix.at!.toLocal().toIso8601String().substring(11, 19),
              ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _refreshing ? null : _forceFresh,
                  icon: _refreshing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 16),
                  label: Text(
                    _refreshing ? 'Polling chip...' : 'Force fresh fix',
                  ),
                ),
              ),
            ],
          ),
          if (_refreshResult != null) ...[
            const SizedBox(height: 8),
            _row(
              cs,
              'forced fix',
              '${_refreshResult!.latitude.toStringAsFixed(6)}, '
                  '${_refreshResult!.longitude.toStringAsFixed(6)}',
            ),
          ],
          if (_refreshError != null) ...[
            const SizedBox(height: 8),
            Text(
              _refreshError!,
              style: const TextStyle(
                color: AppColors.warning,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(ColorScheme cs, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: cs.onSurface,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Green when the fix is fresh (<10 s), amber when growing stale
  /// (<60 s), red when the cache hasn't refreshed in over a minute —
  /// strong visual cue that the always-on keepalive isn't actually
  /// receiving updates from the chip.
  Color _ageColor(Duration? age) {
    if (age == null) return AppColors.warning;
    if (age.inSeconds < 10) return AppColors.accent;
    if (age.inSeconds < 60) return AppColors.warning;
    return AppColors.primary;
  }
}

class _AgeChip extends StatelessWidget {
  const _AgeChip({required this.age, required this.color});
  final Duration? age;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final a = age;
    final label = a == null
        ? '—'
        : a.inDays > 0
        ? '${a.inDays}d ago'
        : a.inHours > 0
        ? '${a.inHours}h ago'
        : a.inMinutes > 0
        ? '${a.inMinutes}m ago'
        : '${a.inSeconds}s ago';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'compat_report.dart';

/// Bounded on-device queue of compat reports. A single JSON-encoded list
/// under [_key] in SharedPreferences — each entry carries its own
/// `uploaded_at` (null = pending).
///
/// `maxQueueSize = 20` keeps SharedPreferences from ballooning on a
/// long-offline device; realistic manual sessions produce ~1–3 reports
/// so this is comfortable headroom. When full, [enqueue] drops the
/// oldest *pending* entry (never an already-uploaded one) to free a
/// slot.
class CompatReportStorage {
  CompatReportStorage(this._prefsFactory);

  /// Indirection so tests can inject an `InMemorySharedPreferences` in
  /// one-line test setups (`SharedPreferences.setMockInitialValues`
  /// would also work but this is explicit).
  final Future<SharedPreferences> Function() _prefsFactory;

  Future<SharedPreferences> get _prefs => _prefsFactory();

  static const _key = 'compat_reports';

  /// Max entries kept in SharedPreferences. Exceeding this on
  /// [enqueue] drops the oldest pending row first.
  static const int maxQueueSize = 20;

  Future<List<CompatReport>> load() async {
    final raw = (await _prefs).getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return [for (final m in list) CompatReport.fromStorageJson(m)];
    } catch (_) {
      // Corrupted prefs blob — start fresh rather than blow up the app.
      return const [];
    }
  }

  Future<void> _save(List<CompatReport> reports) async {
    final encoded = jsonEncode([for (final r in reports) r.toStorageJson()]);
    await (await _prefs).setString(_key, encoded);
  }

  /// Append a new report. Returns the stored copy (same object). If the
  /// queue is already at [maxQueueSize], the oldest pending row is
  /// dropped; if every row is already uploaded (nothing pending to
  /// evict), the oldest uploaded row is dropped as a fallback so
  /// enqueue always succeeds.
  Future<CompatReport> enqueue(CompatReport report) async {
    final current = await load();
    final evicted = _withinLimit([...current, report]);
    await _save(evicted);
    return report;
  }

  /// Replace every stored row whose `reportedAt` matches any of the
  /// given reports — used after a successful upload to stamp
  /// `uploadedAt` onto the right entries.
  Future<void> update(List<CompatReport> updated) async {
    final byKey = <String, CompatReport>{
      for (final r in updated) r.reportedAt.toUtc().toIso8601String(): r,
    };
    final merged = [
      for (final r in await load())
        byKey[r.reportedAt.toUtc().toIso8601String()] ?? r,
    ];
    await _save(merged);
  }

  Future<void> clear() async {
    await (await _prefs).remove(_key);
  }

  /// Overwrite the entire queue with [reports]. Used by the TTL purge in
  /// [CompatReportQueue] — simpler than stitching per-row deletes when
  /// the caller has already computed the kept set.
  Future<void> replace(List<CompatReport> reports) => _save(reports);

  List<CompatReport> _withinLimit(List<CompatReport> reports) {
    if (reports.length <= maxQueueSize) return reports;
    final excess = reports.length - maxQueueSize;
    final copy = [...reports];
    for (var i = 0; i < excess; i++) {
      // Find the oldest pending entry; fall back to the oldest entry
      // overall if nothing is pending.
      final pendingIdx = copy.indexWhere((r) => r.isPending);
      copy.removeAt(pendingIdx >= 0 ? pendingIdx : 0);
    }
    return copy;
  }
}

final compatReportStorageProvider = Provider<CompatReportStorage>((_) {
  return CompatReportStorage(SharedPreferences.getInstance);
});

import 'package:ilink/features/compat/data/compat_report.dart';
import 'package:ilink/features/compat/data/compat_report_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

CompatReport _report(String id, {DateTime? uploadedAt}) {
  // Use reportedAt as a stable key — storage.update matches on it.
  return CompatReport(
    schemaVersion: 1,
    reportedAt: DateTime.utc(2026, 4, 20, 12, int.parse(id)),
    vinHash: null,
    device: const {'app_version': '1.0.0+1'},
    daemon: const {'daemon': true},
    sessionContext: const {},
    commands: const [],
    appNotes: null,
    uploadedAt: uploadedAt,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  late CompatReportStorage storage;

  setUp(() {
    storage = CompatReportStorage(SharedPreferences.getInstance);
  });

  test('enqueue persists and load round-trips', () async {
    final stored = await storage.enqueue(_report('01'));
    final loaded = await storage.load();
    expect(loaded, hasLength(1));
    // Storage normalises to UTC on write + local on read; compare at
    // the UTC representation to be timezone-agnostic.
    expect(loaded.first.reportedAt.toUtc(), stored.reportedAt.toUtc());
    expect(loaded.first.isPending, isTrue);
  });

  test('update stamps uploadedAt by reportedAt key', () async {
    final r = await storage.enqueue(_report('02'));
    await storage.update([r.copyWith(uploadedAt: DateTime.utc(2026, 4, 20))]);
    final loaded = await storage.load();
    expect(loaded.first.uploadedAt, isNotNull);
    expect(loaded.first.isPending, isFalse);
  });

  test('bounded queue — exceeding maxQueueSize drops oldest pending', () async {
    for (var i = 0; i < CompatReportStorage.maxQueueSize + 3; i++) {
      await storage.enqueue(_report(i.toString().padLeft(2, '0')));
    }
    final loaded = await storage.load();
    expect(loaded.length, CompatReportStorage.maxQueueSize);
    // Oldest three should have been evicted.
    final minutes = loaded.map((r) => r.reportedAt.minute).toList();
    expect(minutes.first, greaterThanOrEqualTo(3));
  });

  test('already-uploaded rows are preserved when evicting', () async {
    // Fill with uploaded rows, then enqueue enough pending rows to
    // force eviction. The uploaded rows must survive.
    for (var i = 0; i < 5; i++) {
      await storage.enqueue(
        _report(
          i.toString().padLeft(2, '0'),
          uploadedAt: DateTime.utc(2026, 4, 20),
        ),
      );
    }
    for (var i = 5; i < CompatReportStorage.maxQueueSize + 3; i++) {
      await storage.enqueue(_report(i.toString().padLeft(2, '0')));
    }
    final loaded = await storage.load();
    // All five uploaded rows should still be there.
    expect(loaded.where((r) => !r.isPending).length, 5);
  });

  test('clear empties storage', () async {
    await storage.enqueue(_report('42'));
    await storage.clear();
    expect(await storage.load(), isEmpty);
  });
}

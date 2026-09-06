import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/workflow/data/workflow_store.dart';

StoredWorkflow _row(String id, {bool local = false}) => StoredWorkflow(
  id: id,
  rev: local ? 2 : 1,
  docSha256: local ? 'local' : 'original',
  enabled: true,
  installId: null,
  document: {'workflowId': id},
  localModified: local,
);

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('workflow-races-');
  });
  tearDown(() async => directory.delete(recursive: true));

  for (final remove in [false, true]) {
    test(
      'local save serializes with pending ${remove ? 'delete' : 'edit'}',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        var rootCalls = 0;
        final store = WorkflowStore(
          appSupportDirFactory: () async {
            rootCalls++;
            if (rootCalls == 1) {
              entered.complete();
              await release.future;
            }
            return directory;
          },
        );
        final sync = store.put(_row('shared'));
        await entered.future;
        final edit = remove
            ? store.remove('shared')
            : store.put(_row('shared', local: true));
        // Let the queued mutation start if no common lock protects the store.
        await Future<void>.delayed(Duration.zero);
        final callsWhileHeld = rootCalls;
        release.complete();
        await Future.wait([sync, edit]);
        expect(
          callsWhileHeld,
          1,
          reason: 'a local mutation must wait for the previous write',
        );
        final rows = await store.loadAll();
        if (remove) {
          expect(rows, isEmpty);
        } else {
          expect(rows.single.docSha256, 'local');
        }
      },
    );
  }

  test('failed mutation does not poison later local writes', () async {
    var fail = true;
    final store = WorkflowStore(
      appSupportDirFactory: () async {
        if (fail) {
          fail = false;
          throw const FileSystemException('temporarily unavailable');
        }
        return directory;
      },
    );
    await expectLater(
      store.put(_row('failed')),
      throwsA(isA<FileSystemException>()),
    );
    await store.put(_row('saved', local: true));
    expect((await store.loadAll()).single.id, 'saved');
  });
}

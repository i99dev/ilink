import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/workflow/data/local_workflow_repository.dart';
import 'package:ilink/features/workflow/data/workflow_store.dart';

Map<String, Object?> _document() => {
  'workflowId': 'device-test',
  'name': 'Local automation',
  'nodes': [
    {
      'id': 'trigger',
      'kind': 'trigger',
      'type': 'signal.threshold',
      'config': {'name': 'battery_pct', 'op': '<', 'value': 20},
    },
    {
      'id': 'action',
      'kind': 'action',
      'type': 'car_command',
      'config': {'actionId': 'climate.power.on'},
      'flags': {'securityClass': 'none'},
    },
  ],
  'edges': [
    {'from': 'trigger', 'to': 'action'},
  ],
};

void main() {
  late Directory directory;
  late WorkflowStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('offline-workflows-');
    store = WorkflowStore(appSupportDirFactory: () async => directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'local create/edit/enable survives repository restart without backend',
    () async {
      var changes = 0;
      final repo = LocalWorkflowRepository(
        store,
        onChanged: () async {
          changes++;
        },
      );
      final created = await repo.save({'document': _document()});
      expect(created.id, startsWith('local_'));
      expect(created.enabled, isFalse);
      await repo.save({'id': created.id, 'name': 'Edited'});
      await repo.setEnabled(created.id, true);
      final restored = await WorkflowStore(
        appSupportDirFactory: () async => directory,
      ).loadAll();
      expect(restored.single.document['name'], 'Edited');
      expect(restored.single.enabled, isTrue);
      expect(restored.single.rev, 3);
      expect(changes, 3);
    },
  );

  test(
    'bad document and path traversal never write an executable workflow',
    () async {
      final repo = LocalWorkflowRepository(store, onChanged: () async {});
      await expectLater(
        repo.save({
          'document': {'workflowId': 'bad'},
        }),
        throwsFormatException,
      );
      await expectLater(
        repo.save({'id': '../escape', 'document': _document()}),
        throwsFormatException,
      );
      expect(await store.loadAll(), isEmpty);
    },
  );

  test('an existing imported row can be edited and deleted locally', () async {
    await store.put(
      StoredWorkflow(
        id: 'legacy-row',
        rev: 1,
        docSha256: 'existing',
        enabled: true,
        installId: null,
        document: _document(),
      ),
    );
    final repo = LocalWorkflowRepository(store, onChanged: () async {});
    await repo.save({'id': 'legacy-row', 'name': 'Local edit'});
    expect((await store.loadAll()).single.document['name'], 'Local edit');
    await repo.remove('legacy-row');
    expect(await store.loadAll(), isEmpty);
  });
}

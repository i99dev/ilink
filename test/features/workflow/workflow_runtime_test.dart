import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/workflow/engine/compiled_workflow.dart';
import 'package:ilink/features/workflow/data/workflow_store.dart';
import 'package:ilink/features/workflow/data/workflow_runtime.dart';

Map<String, Object?> _doc(String wfId) => {
  'workflowId': wfId,
  'name': 'x',
  'nodes': [
    {
      'id': 't',
      'kind': 'trigger',
      'type': 'signal.threshold',
      'config': {'name': 'battery_pct', 'op': '<', 'value': 20},
    },
    {
      'id': 'a',
      'kind': 'action',
      'type': 'car_command',
      'config': {'actionId': 'climate.power.on'},
      'flags': {'securityClass': 'none'},
    },
  ],
  'edges': [
    {'from': 't', 'to': 'a'},
  ],
};

void main() {
  late Directory tmp;
  late WorkflowStore store;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('workflow-local-');
    store = WorkflowStore(appSupportDirFactory: () async => tmp);
  });
  tearDown(() async => tmp.delete(recursive: true));

  test(
    'saved legacy rows reload; disabled, other-install and invalid documents never arm',
    () async {
      for (final id in ['active', 'disabled', 'other', 'invalid']) {
        await store.put(
          StoredWorkflow(
            id: id,
            rev: 2,
            docSha256: 'existing',
            enabled: id != 'disabled',
            installId: id == 'other' ? 'other-car' : null,
            document: id == 'invalid' ? {'workflowId': id} : _doc(id),
          ),
        );
      }
      final published = <List<CompiledWorkflow>>[];
      final restored = WorkflowStore(appSupportDirFactory: () async => tmp);
      final service = LocalWorkflowRuntime(
        store: restored,
        currentInstallId: () => 'my-car',
        publish: published.add,
      );
      await service.bootFromStore();
      expect(published.single.map((w) => w.id), ['active']);
      expect(await restored.loadAll(), hasLength(4));
      await restored.remove('active');
      await service.bootFromStore();
      expect(published.last, isEmpty);
    },
  );

  test('corrupt file does not prevent valid local workflows loading', () async {
    await store.put(
      StoredWorkflow(
        id: 'valid',
        rev: 1,
        docSha256: '',
        enabled: true,
        installId: null,
        document: _doc('valid'),
      ),
    );
    await File('${tmp.path}/workflows/corrupt.json').writeAsString('{broken');
    expect((await store.loadAll()).single.id, 'valid');
  });

  test('unsafe row IDs cannot escape the store', () async {
    await store.put(
      StoredWorkflow(
        id: '../escape',
        rev: 1,
        docSha256: '',
        enabled: true,
        installId: null,
        document: _doc('escape'),
      ),
    );
    expect(await store.loadAll(), isEmpty);
    expect(await File('${tmp.path}/escape.json').exists(), isFalse);
  });
}

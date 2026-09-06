import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/workflow_providers.dart';
import '../data/workflow_store.dart';

/// Workflow CRUD persists on the head unit and immediately re-arms the engine.
class WorkflowBridgeService {
  WorkflowBridgeService(this._ref);
  final Ref _ref;
  Map<String, Object?> _record(StoredWorkflow row) => {
    'id': row.id,
    'name': row.document['name'] ?? 'Automation',
    'rev': row.rev,
    'doc_sha256': row.docSha256,
    'enabled': row.enabled,
    'install_id': row.installId,
    'document': row.document,
    'source': 'authored',
  };
  Future<Map<String, Object?>> _run(
    Future<Map<String, Object?>> Function() op,
  ) async {
    try {
      return await op();
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<Map<String, Object?>> list() => _run(
    () async => {
      'workflows': [
        for (final row
            in await _ref.read(localWorkflowRepositoryProvider).list())
          _record(row),
      ],
    },
  );
  Future<Map<String, Object?>> save(Map<String, Object?> args) => _run(
    () async =>
        _record(await _ref.read(localWorkflowRepositoryProvider).save(args)),
  );
  Future<Map<String, Object?>> setEnabled(Map<String, Object?> args) => _run(
    () async => _record(
      await _ref
          .read(localWorkflowRepositoryProvider)
          .setEnabled(args['id'] as String? ?? '', args['enabled'] == true),
    ),
  );
  Future<Map<String, Object?>> remove(Map<String, Object?> args) =>
      _run(() async {
        final id = args['id'] as String?;
        if (id == null || id.isEmpty) return {'error': 'missing id'};
        await _ref.read(localWorkflowRepositoryProvider).remove(id);
        return {'deleted': true};
      });
  // Community publishing requires a shared service and has been retired.
  Future<Map<String, Object?>> templates(Map<String, Object?> args) async => {
    'templates': const [],
    'unavailable': 'Community template service has been retired.',
  };
  Future<Map<String, Object?>> myTemplates() => templates(const {});
  Future<Map<String, Object?>> getTemplate(Map<String, Object?> args) async => {
    'error': 'Community template service has been retired.',
  };
  Future<Map<String, Object?>> publishTemplate(Map<String, Object?> args) =>
      getTemplate(args);
  Future<Map<String, Object?>> importTemplate(Map<String, Object?> args) async {
    if (args['document'] is! Map) return getTemplate(args);
    return save({...args, 'id': null, 'enabled': false});
  }
}

final workflowBridgeServiceProvider = Provider<WorkflowBridgeService>(
  (ref) => WorkflowBridgeService(ref),
);

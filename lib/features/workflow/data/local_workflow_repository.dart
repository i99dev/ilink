import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../engine/compiled_workflow.dart';
import 'workflow_store.dart';

abstract interface class WorkflowRepository {
  Future<List<StoredWorkflow>> list();
  Future<StoredWorkflow> save(Map<String, Object?> args);
  Future<StoredWorkflow> setEnabled(String id, bool enabled);
  Future<void> remove(String id);
}

/// Actual local CRUD using the same document compiler and execution engine.
class LocalWorkflowRepository implements WorkflowRepository {
  LocalWorkflowRepository(this.store, {required this.onChanged});
  final WorkflowStore store;
  final Future<void> Function() onChanged;
  Future<void> _pending = Future.value();

  Future<T> _mutate<T>(Future<T> Function() action) {
    final task = _pending.then((_) => action());
    _pending = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  @override
  Future<List<StoredWorkflow>> list() => store.loadAll();

  @override
  Future<StoredWorkflow> save(Map<String, Object?> args) => _mutate(() async {
    final requestedId = args['id'] as String?;
    final id = requestedId == null || requestedId.isEmpty
        ? 'local_${const Uuid().v4()}'
        : requestedId;
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      throw const FormatException('Invalid workflow id');
    }
    final matches = (await store.loadAll()).where((w) => w.id == id);
    final prior = matches.isEmpty ? null : matches.first;
    if (requestedId != null && requestedId.isNotEmpty && prior == null) {
      throw const FormatException('Workflow not found');
    }
    final raw = args['document'] ?? prior?.document;
    if (raw is! Map) {
      throw const FormatException('Workflow document is required');
    }
    final document = <String, Object?>{...raw.cast<String, Object?>()};
    if (args['name'] != null) document['name'] = args['name'];
    final compiled = compileWorkflowDocument(document);
    if (!compiled.ok) {
      throw FormatException(compiled.error ?? 'Unsupported workflow');
    }
    final row = StoredWorkflow(
      id: id,
      rev: (prior?.rev ?? 0) + 1,
      docSha256: sha256.convert(utf8.encode(jsonEncode(document))).toString(),
      enabled: args['enabled'] as bool? ?? prior?.enabled ?? false,
      installId: prior?.installId ?? args['install_id'] as String?,
      document: document,
      localModified: true,
    );
    await store.put(row);
    await onChanged();
    return row;
  });

  @override
  Future<StoredWorkflow> setEnabled(String id, bool enabled) =>
      save({'id': id, 'enabled': enabled});

  @override
  Future<void> remove(String id) => _mutate(() async {
    await store.remove(id);
    await onChanged();
  });
}

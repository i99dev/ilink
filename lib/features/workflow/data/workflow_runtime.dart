library;

import 'package:flutter/foundation.dart';

import '../engine/compiled_workflow.dart';
import 'workflow_store.dart';

/// Compiles enabled local workflows into the execution engine.
class LocalWorkflowRuntime {
  LocalWorkflowRuntime({
    required WorkflowStore store,
    required String? Function() currentInstallId,
    required void Function(List<CompiledWorkflow>) publish,
  }) : _store = store,
       _currentInstallId = currentInstallId,
       _publish = publish;

  final WorkflowStore _store;
  final String? Function() _currentInstallId;
  final void Function(List<CompiledWorkflow>) _publish;

  /// Reload the persisted workflows after startup or a local edit.
  Future<void> bootFromStore() async {
    final stored = await _store.loadAll();
    _publish(_compileInScope(stored));
  }

  /// Compile every enabled, in-scope workflow; drop (with a log) any the
  /// engine can't run. An unpinned workflow or one pinned to this install may run.
  List<CompiledWorkflow> _compileInScope(List<StoredWorkflow> stored) {
    final mine = _currentInstallId();
    final out = <CompiledWorkflow>[];
    for (final s in stored) {
      if (!s.enabled) continue;
      if (s.installId != null && s.installId != mine) continue;
      final result = compileWorkflowDocument(s.document);
      if (result.ok) {
        out.add(result.workflow!);
      } else {
        debugPrint(
          '[workflow] dropped "${s.id}" (not runnable): ${result.error}',
        );
      }
    }
    return out;
  }
}

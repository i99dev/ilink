/// Local workflow storage, engine reload and boot registration.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:ilink/features/workflow/domain/workflow_summary.dart';

import '../../../platform/device/install_id_provider.dart';

import '../engine/workflow_engine_provider.dart';
import 'workflow_store.dart';
import 'local_workflow_repository.dart';

import 'workflow_runtime.dart';

final workflowStoreProvider = Provider<WorkflowStore>((ref) => WorkflowStore());

final localWorkflowRuntimeProvider = Provider<LocalWorkflowRuntime>((ref) {
  return LocalWorkflowRuntime(
    store: ref.read(workflowStoreProvider),
    currentInstallId: () => ref.read(installIdProvider).value,
    publish: (workflows) =>
        ref.read(enabledWorkflowsProvider.notifier).set(workflows),
  );
});

/// Revision signal for locally edited workflow summaries.
final workflowRevisionProvider = NotifierProvider<WorkflowRevision, int>(
  WorkflowRevision.new,
);

class WorkflowRevision extends Notifier<int> {
  @override
  int build() => 0;
  void changed() => state++;
}

final localWorkflowRepositoryProvider = Provider<WorkflowRepository>(
  (ref) => LocalWorkflowRepository(
    ref.watch(workflowStoreProvider),
    onChanged: () async {
      await ref.read(localWorkflowRuntimeProvider).bootFromStore();
      ref.read(workflowRevisionProvider.notifier).changed();
    },
  ),
);

final localWorkflowDigestProvider = FutureProvider<List<WorkflowSummary>>((
  ref,
) async {
  ref.watch(workflowRevisionProvider);
  return [
    for (final w in await ref.watch(workflowStoreProvider).loadAll())
      WorkflowSummary(
        id: w.id,
        name: w.document['name'] as String? ?? 'Automation',
        rev: w.rev,
        docSha256: w.docSha256,
        enabled: w.enabled,
        installId: w.installId,
      ),
  ];
});

final localWorkflowRegistrationProvider = Provider<void>((ref) {
  unawaited(
    ref
        .read(localWorkflowRuntimeProvider)
        .bootFromStore()
        .catchError(
          (Object e) => debugPrint('[workflow] local store unavailable'),
        ),
  );
});

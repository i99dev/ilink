import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/workflow/data/workflow_store.dart';
import 'package:ilink/features/workflow/data/workflow_providers.dart';
import 'package:ilink/features/workflow/data/workflow_runtime.dart';

void main() {
  test(
    'boot registration publishes locally saved workflows without an account',
    () async {
      final dir = await Directory.systemTemp.createTemp('workflow-local-boot-');
      addTearDown(() => dir.delete(recursive: true));
      final store = WorkflowStore(appSupportDirFactory: () async => dir);
      final published = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          localWorkflowRuntimeProvider.overrideWithValue(
            LocalWorkflowRuntime(
              store: store,
              currentInstallId: () => null,
              publish: (rows) {
                expect(rows, isEmpty);
                published.complete();
              },
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(localWorkflowRegistrationProvider);
      await published.future.timeout(const Duration(seconds: 5));
    },
  );
}

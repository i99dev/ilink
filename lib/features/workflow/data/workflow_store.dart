/// Atomic local workflow storage. Existing document IDs and install bindings
/// remain readable after upgrading from older releases.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One persisted local workflow.
class StoredWorkflow {
  const StoredWorkflow({
    required this.id,
    required this.rev,
    required this.docSha256,
    required this.enabled,
    required this.installId,
    required this.document,
    this.localModified = false,
  });

  final String id;
  final int rev;
  final String docSha256;
  final bool enabled;

  /// Null means this document is not pinned to one installation.
  final String? installId;
  final Map<String, Object?> document;
  final bool localModified;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'rev': rev,
    'docSha256': docSha256,
    'enabled': enabled,
    'installId': installId,
    'document': document,
    'localModified': localModified,
  };

  static StoredWorkflow? fromJson(Map<String, Object?> j) {
    final id = j['id'];
    final document = j['document'];
    if (id is! String || document is! Map) return null;
    return StoredWorkflow(
      id: id,
      rev: (j['rev'] as num?)?.toInt() ?? 1,
      docSha256: (j['docSha256'] as String?) ?? '',
      enabled: (j['enabled'] as bool?) ?? false,
      installId: j['installId'] as String?,
      document: document.cast<String, Object?>(),
      localModified: j['localModified'] == true,
    );
  }
}

class WorkflowStore {
  WorkflowStore({Future<Directory> Function()? appSupportDirFactory})
    : _appSupportDirFactory =
          appSupportDirFactory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _appSupportDirFactory;
  Future<void> _pending = Future.value();

  // Serialize reads and writes so the engine observes completed mutations.
  Future<T> _serialize<T>(Future<T> Function() action) {
    final task = _pending.then((_) => action());
    _pending = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  static const String _kRootDirName = 'workflows';
  static final RegExp _safeId = RegExp(r'^[A-Za-z0-9_-]+$');

  Future<Directory> _root() async {
    final base = await _appSupportDirFactory();
    final root = Directory(p.join(base.path, _kRootDirName));
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  /// Load every persisted workflow, skipping corrupt/partial files
  /// (best-effort — a bad file never blocks the rest from arming).
  Future<List<StoredWorkflow>> loadAll() => _serialize(() async {
    return _loadAll(await _root());
  });

  Future<List<StoredWorkflow>> _loadAll(Directory root) async {
    final out = <StoredWorkflow>[];
    await for (final entry in root.list()) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(await entry.readAsString());
        if (decoded is Map<String, dynamic>) {
          final wf = StoredWorkflow.fromJson(decoded);
          if (wf != null) out.add(wf);
        }
      } catch (_) {
        // Corrupt file — ignore; reconcile will overwrite or prune it.
      }
    }
    return out;
  }

  Future<void> put(StoredWorkflow wf) => _serialize(() async {
    if (!_safeId.hasMatch(wf.id)) return; // never write outside the directory
    await _put(await _root(), wf);
  });

  Future<void> _put(Directory root, StoredWorkflow wf) async {
    final target = File(p.join(root.path, '${wf.id}.json'));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(wf.toJson()), flush: true);
    await tmp.rename(target.path);
  }

  Future<void> remove(String id) => _serialize(() async {
    if (!_safeId.hasMatch(id)) return;
    final root = await _root();
    final f = File(p.join(root.path, '$id.json'));
    if (await f.exists()) await f.delete();
  });
}

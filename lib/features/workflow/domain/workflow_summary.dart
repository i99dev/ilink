/// Summary of a locally stored workflow used by control surfaces.
class WorkflowSummary {
  const WorkflowSummary({
    required this.id,
    required this.name,
    required this.rev,
    required this.docSha256,
    required this.enabled,
    this.installId,
  });

  final String id;

  /// Human label for on-device control surfaces (the home workflow
  /// sheet). Carried in the digest so no extra fetch is needed to show
  /// the user which automation is which.
  final String name;
  final int rev;
  final String docSha256;
  final bool enabled;

  /// Null means the workflow is not pinned to a particular installation.
  final String? installId;

  static WorkflowSummary? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    if (id is! String) return null;
    return WorkflowSummary(
      id: id,
      name: (j['name'] as String?)?.trim().isNotEmpty == true
          ? (j['name'] as String).trim()
          : 'Automation',
      rev: (j['rev'] as num?)?.toInt() ?? 1,
      docSha256: (j['doc_sha256'] as String?) ?? '',
      enabled: (j['enabled'] as bool?) ?? false,
      installId: j['install_id'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WorkflowSummary &&
      other.id == id &&
      other.name == name &&
      other.rev == rev &&
      other.docSha256 == docSha256 &&
      other.enabled == enabled &&
      other.installId == installId;

  @override
  int get hashCode => Object.hash(id, name, rev, docSha256, enabled, installId);
}

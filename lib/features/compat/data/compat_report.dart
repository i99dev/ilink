/// Shape of a single compat report persisted locally and sent to the
/// backend. The `schema_version` field is load-bearing — old APKs keep
/// uploading v1 while the backend grows, so the server-side parser
/// fans out by version (see backend/app/api/v1/compat/service.py).
///
/// Kept as a plain record-style class (not code-gen) because
/// json_serializable isn't in the project — the JSON shape matches the
/// backend Pydantic schema 1:1 by convention, enforced by the Compat
/// test suite.
class CompatReport {
  const CompatReport({
    required this.schemaVersion,
    required this.reportedAt,
    required this.vinHash,
    required this.device,
    required this.daemon,
    required this.sessionContext,
    required this.commands,
    required this.appNotes,
    this.benchRuns = const [],
    this.binderProbes = const [],
    this.source = 'compat_screen',
    this.uploadedAt,
  });

  final int schemaVersion;
  final DateTime reportedAt;

  /// 16-hex-char sha256 of the VIN + app salt. `null` = user opted out.
  final String? vinHash;

  /// Identity of the head-unit / BYD stack. All keys optional because
  /// `car.identity` may return a partial map on cars where reflection
  /// probes fail.
  final Map<String, dynamic> device;

  /// Live bridge state at scan time.
  final Map<String, dynamic> daemon;

  /// State-dependent telemetry — a headlight command that "doesn't
  /// work" means something different if the car was off.
  final Map<String, dynamic> sessionContext;

  /// One entry per registry command. Shape is `ProbeResult.toJson()`
  /// plus an optional `user_verdict` ∈ {worked, didnt, unclear, null}.
  final List<Map<String, dynamic>> commands;

  /// One entry per actuator fired from the dev test bench. Each row
  /// captures `(action_id, args, ok, code, error, run_at)` so the
  /// matrix aggregator can map "what we sent" → "what the daemon
  /// returned" without rerunning the test on a different DiLink.
  /// Empty when the report comes from the compat scanner.
  final List<Map<String, dynamic>> benchRuns;

  /// One entry per AIDL binder transact fired from the test bench
  /// (`@service.method` form). Distinct from [benchRuns] because the
  /// matrix aggregator needs to filter by service availability — some
  /// DiLink builds expose the action but not the binder, or vice versa.
  final List<Map<String, dynamic>> binderProbes;

  /// Free-form "any other context" text from the user.
  final String? appNotes;

  /// Which surface produced the report: `compat_screen` (probe + manual
  /// verdict grid), `dev_bench` (per-action fire bench), or anything
  /// else added later. Lets the admin matrix view filter to a single
  /// data source — bench reports are typically richer than verdict-grid
  /// reports because they include actual wire result codes.
  final String source;

  /// When this report was successfully POSTed to the backend. `null`
  /// means it's still pending in the local queue.
  final DateTime? uploadedAt;

  bool get isPending => uploadedAt == null;

  CompatReport copyWith({DateTime? uploadedAt}) => CompatReport(
    schemaVersion: schemaVersion,
    reportedAt: reportedAt,
    vinHash: vinHash,
    device: device,
    daemon: daemon,
    sessionContext: sessionContext,
    commands: commands,
    benchRuns: benchRuns,
    binderProbes: binderProbes,
    source: source,
    appNotes: appNotes,
    uploadedAt: uploadedAt ?? this.uploadedAt,
  );

  /// The payload actually uploaded to the backend — without the local
  /// `uploadedAt` bookkeeping (the server timestamps received_at itself).
  Map<String, dynamic> toUploadJson() => {
    'schema_version': schemaVersion,
    'reported_at': reportedAt.toUtc().toIso8601String(),
    'vin_hash': vinHash,
    'device': device,
    'daemon': daemon,
    'session_context': sessionContext,
    'commands': commands,
    'bench_runs': benchRuns,
    'binder_probes': binderProbes,
    'source': source,
    'app_notes': appNotes,
  };

  /// Full on-device serialization, including local metadata.
  Map<String, dynamic> toStorageJson() => {
    ...toUploadJson(),
    if (uploadedAt != null)
      'uploaded_at': uploadedAt!.toUtc().toIso8601String(),
  };

  factory CompatReport.fromStorageJson(
    Map<String, dynamic> json,
  ) => CompatReport(
    schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 1,
    reportedAt:
        DateTime.tryParse(json['reported_at'] as String? ?? '')?.toLocal() ??
        DateTime.now(),
    vinHash: json['vin_hash'] as String?,
    device: (json['device'] as Map?)?.cast<String, dynamic>() ?? const {},
    daemon: (json['daemon'] as Map?)?.cast<String, dynamic>() ?? const {},
    sessionContext:
        (json['session_context'] as Map?)?.cast<String, dynamic>() ?? const {},
    commands: ((json['commands'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList(),
    benchRuns: ((json['bench_runs'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList(),
    binderProbes: ((json['binder_probes'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList(),
    source: (json['source'] as String?) ?? 'compat_screen',
    appNotes: json['app_notes'] as String?,
    uploadedAt: json['uploaded_at'] == null
        ? null
        : DateTime.tryParse(json['uploaded_at'] as String)?.toLocal(),
  );
}

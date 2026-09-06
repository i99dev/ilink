/// Wire shapes for the `display` family. Pure data — no platform
/// imports — so tests and the SDK contract roundtrip share one
/// source of truth.
library;

class DisplaySnapshot {
  const DisplaySnapshot({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.densityDpi,
    required this.isDefault,
    required this.isPresentation,
    required this.isCluster,
    this.role = 'unknown',
    this.source = 'unknown',
    this.confidence = 'medium',
    this.dimReason,
    this.hidden = false,
    this.overrideLabel,
    this.clusterAvailable = true,
    this.castMode = 'launch',
    this.displayGroupId,
    this.castClass = 'not_cluster',
    this.derivedCastMechanism = 'unreachable',
    int? cursorDisplayId,
    int? inputSourceDisplayId,
    int? zoomDisplayId,
  }) : cursorDisplayId = cursorDisplayId ?? id,
       inputSourceDisplayId = inputSourceDisplayId ?? id,
       zoomDisplayId = zoomDisplayId ?? id;

  final int id;
  final String name;
  final int width;
  final int height;
  final int densityDpi;
  final bool isDefault;
  final bool isPresentation;
  final bool isCluster;

  /// Mini-app-facing role classification: `ivi`, `passenger`,
  /// `cluster`, or `unknown`. This is the field `pkg.launch` /
  /// `pkg.launch_cluster` consult to decide whether the caller's
  /// permission scope covers the requested display. Native source
  /// of truth lives in `DisplayRoles.kt`; the SDK reads `role`
  /// directly from `display.list`. `isCluster` remains for the
  /// initial Phase-A SDK clients but is now derived from
  /// `role == 'cluster'` host-side.
  final String role;

  /// Which classifier layer fired. One of `'MARKER'` /
  /// `'NAME_KW'` / `'CACHE_HIT'` / `'DEFAULT'` / `'unknown'`.
  /// Lets observability + mini-apps know how confident the role
  /// classification is. Defaults to `'unknown'` when the host
  /// shipped before the field existed (Phase 2 / 1.5.3+).
  final String source;

  /// Confidence tier of the classification — `'HIGH'` or `'MEDIUM'`.
  /// HIGH means a positive signal fired (encrypted marker / name
  /// keyword / cache hit). MEDIUM means we fell through to the safe
  /// default. Defaults to `'medium'` for backward-compat with older
  /// hosts.
  final String confidence;

  /// Hint string when the active `VehicleProfile` flags this display
  /// as a duplicate / shadow on the trim. Pickers should DIM the
  /// display with this reason but NEVER hide it. Replaces the
  /// older [hidden] hard-filter semantics. Null when no hint.
  final String? dimReason;

  /// DEPRECATED in favour of [dimReason]. True for displays the
  /// active `VehicleProfile` flags as duplicate / shadow surfaces
  /// (derived from `dimReason != null` host-side for back-compat).
  /// New consumers should read [dimReason] and dim, not hide.
  final bool hidden;

  /// Friendlier label from the active `VehicleProfile` — e.g.
  /// `"Driver"` for the cluster display on L8 / L5L. Null means
  /// callers should fall back to [name].
  final String? overrideLabel;

  /// Active profile's `showCluster` flag — false on Leopard 5
  /// (base / Ultra) / Leopard 7 / BYD HAN L per empirical data.
  /// Mini-apps read this to pre-empt rendering cluster UI on cars
  /// where the OS doesn't expose the cluster as a reachable
  /// `Display`. Defaults to true (Generic fallback) when the host
  /// hasn't profiled this trim.
  final bool clusterAvailable;

  /// How a cast to this display is delivered: `'launch'` (the default —
  /// existing launchCluster / displayId launch path) or `'project'`
  /// (cast a foreign app via OUR own VirtualDisplay — the reference
  /// mechanism — used for XDJA OWN_CONTENT_ONLY fission cluster displays
  /// where move-task / a direct launch hangs the head unit, e.g. L7
  /// display 4). The DISPLAYS drop picker routes `'project'` through
  /// `pkg.projectToCluster`. Defaults to `'launch'` for back-compat.
  final String castMode;

  /// Android display-group id (reflection on the host), or null when the
  /// ROM lacks `Display.getDisplayGroupId()`. The dynamic cluster policy
  /// uses "shares the IVI's group" as the group-0 fission-hazard signal.
  final int? displayGroupId;

  /// The cluster cast-class the dynamic [ClusterCastPolicy] (host-side)
  /// derived: `not_cluster` / `launchable_xdja` / `group0_fission_hazard` /
  /// `byd_container_cluster` / `unknown_cluster`. Read-only in Phase 1
  /// (surfaced for on-car verification; does NOT yet drive launch — that's
  /// still [castMode]).
  final String castClass;

  /// The cast mechanism the dynamic policy WOULD use: `ivi_local` /
  /// `am_start` / `project` / `shell_launch` / `dishare` / `unreachable`.
  /// Compared against today's static [castMode] on-car before it drives
  /// launches (Phase 2). Defaults to `'unreachable'`.
  final String derivedCastMechanism;

  /// Where the pointer / cursor should render when the *logical*
  /// surface is this display. Mirrors the per-trim `cursorRemap` in
  /// `VehicleProfile.kt`. Equal to [id] on trims with no remap.
  final int cursorDisplayId;

  /// Where touch / input *originating from* this display should be
  /// routed for app-level event delivery. Mirrors the per-trim
  /// `inputRemap` in `VehicleProfile.kt`. Equal to [id] on trims
  /// with no remap.
  final int inputSourceDisplayId;

  /// Where `wm density -d N` should land when the user requests
  /// zoom on this display. Mirrors the per-trim `zoomRemap` in
  /// `VehicleProfile.kt`. Equal to [id] on trims with no remap.
  final int zoomDisplayId;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'width': width,
    'height': height,
    'densityDpi': densityDpi,
    'isDefault': isDefault,
    'isPresentation': isPresentation,
    'isCluster': isCluster,
    'role': role,
    'source': source,
    'confidence': confidence,
    if (dimReason != null) 'dimReason': dimReason,
    'hidden': hidden,
    if (overrideLabel != null) 'overrideLabel': overrideLabel,
    'clusterAvailable': clusterAvailable,
    'castMode': castMode,
    if (displayGroupId != null) 'displayGroupId': displayGroupId,
    'castClass': castClass,
    'derivedCastMechanism': derivedCastMechanism,
    'cursorDisplayId': cursorDisplayId,
    'inputSourceDisplayId': inputSourceDisplayId,
    'zoomDisplayId': zoomDisplayId,
  };

  factory DisplaySnapshot.fromMap(Map<String, Object?> m) {
    final id = (m['id'] as num).toInt();
    return DisplaySnapshot(
      id: id,
      name: m['name'] as String? ?? '',
      width: (m['width'] as num?)?.toInt() ?? 0,
      height: (m['height'] as num?)?.toInt() ?? 0,
      densityDpi: (m['densityDpi'] as num?)?.toInt() ?? 0,
      isDefault: m['isDefault'] as bool? ?? false,
      isPresentation: m['isPresentation'] as bool? ?? false,
      isCluster: m['isCluster'] as bool? ?? false,
      // Default 'unknown' so older native side (no `role` key) parses
      // without throwing — same conservative default the wire shape
      // returns for displays we can't classify.
      role: m['role'] as String? ?? 'unknown',
      // Phase 2 fields — default gracefully on older hosts so a
      // mid-rollout SDK doesn't crash mini-apps. Old wire shape (no
      // source / confidence keys) parses as 'unknown' / 'medium'
      // which means "we don't know how this was classified" — safe
      // signal that means "treat conservatively."
      source: m['source'] as String? ?? 'unknown',
      confidence: m['confidence'] as String? ?? 'medium',
      dimReason: m['dimReason'] as String?,
      hidden: m['hidden'] as bool? ?? false,
      overrideLabel: m['overrideLabel'] as String?,
      // Default true so an older host that doesn't ship the
      // VehicleProfile fields doesn't accidentally flip mini-apps
      // into "no cluster" mode on a car where the cluster works.
      clusterAvailable: m['clusterAvailable'] as bool? ?? true,
      castMode: m['castMode'] as String? ?? 'launch',
      // Phase-1 cast-policy fields — default safe on older hosts.
      displayGroupId: (m['displayGroupId'] as num?)?.toInt(),
      castClass: m['castClass'] as String? ?? 'not_cluster',
      derivedCastMechanism:
          m['derivedCastMechanism'] as String? ?? 'unreachable',
      cursorDisplayId: (m['cursorDisplayId'] as num?)?.toInt() ?? id,
      inputSourceDisplayId: (m['inputSourceDisplayId'] as num?)?.toInt() ?? id,
      zoomDisplayId: (m['zoomDisplayId'] as num?)?.toInt() ?? id,
    );
  }
}

enum DisplayEventKind { snapshot, added, removed, changed }

DisplayEventKind _parseKind(String? s) => switch (s) {
  'snapshot' => DisplayEventKind.snapshot,
  'added' => DisplayEventKind.added,
  'removed' => DisplayEventKind.removed,
  'changed' => DisplayEventKind.changed,
  _ => DisplayEventKind.changed,
};

class DisplayEvent {
  const DisplayEvent({
    required this.kind,
    this.displayId,
    this.display,
    this.displays,
  });

  final DisplayEventKind kind;
  final int? displayId;
  final DisplaySnapshot? display;
  final List<DisplaySnapshot>? displays;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': kind.name,
    if (displayId != null) 'displayId': displayId,
    if (display != null) 'display': display!.toJson(),
    if (displays != null) 'displays': displays!.map((d) => d.toJson()).toList(),
  };

  factory DisplayEvent.fromMap(Map<String, Object?> m) {
    final kind = _parseKind(m['type'] as String?);
    final rawList = m['displays'] as List?;
    final rawSingle = m['display'] as Map?;
    return DisplayEvent(
      kind: kind,
      displayId: (m['displayId'] as num?)?.toInt(),
      display: rawSingle == null
          ? null
          : DisplaySnapshot.fromMap(rawSingle.cast<String, Object?>()),
      displays: rawList
          ?.map(
            (e) => DisplaySnapshot.fromMap((e as Map).cast<String, Object?>()),
          )
          .toList(growable: false),
    );
  }
}

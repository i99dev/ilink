/// Wire shapes for the `surface` family.
library;

class SurfaceCreateResult {
  const SurfaceCreateResult({
    required this.surfaceId,
    required this.path,
    required this.displayId,
    required this.route,
  });

  final String surfaceId;
  final String path; // 'presentation' | 'overlay' | 'denied'
  final int displayId;
  final String route;

  Map<String, Object?> toJson() => <String, Object?>{
    'surfaceId': surfaceId,
    'path': path,
    'displayId': displayId,
    'route': route,
  };

  factory SurfaceCreateResult.fromMap(Map<String, Object?> m) =>
      SurfaceCreateResult(
        surfaceId: m['surfaceId'] as String? ?? '',
        path: m['path'] as String? ?? 'denied',
        displayId: (m['displayId'] as num?)?.toInt() ?? -1,
        route: m['route'] as String? ?? '/',
      );
}

class SurfaceSnapshot {
  const SurfaceSnapshot({
    required this.surfaceId,
    required this.displayId,
    required this.path,
    required this.route,
  });

  final String surfaceId;
  final int displayId;
  final String path;
  final String route;

  Map<String, Object?> toJson() => <String, Object?>{
    'surfaceId': surfaceId,
    'displayId': displayId,
    'path': path,
    'route': route,
  };

  factory SurfaceSnapshot.fromMap(Map<String, Object?> m) => SurfaceSnapshot(
    surfaceId: m['id'] as String? ?? '',
    displayId: (m['displayId'] as num?)?.toInt() ?? -1,
    path: m['path'] as String? ?? 'denied',
    route: m['route'] as String? ?? '/',
  );
}

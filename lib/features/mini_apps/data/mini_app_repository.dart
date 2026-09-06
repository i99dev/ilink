import 'package:dio/dio.dart';

import '../domain/mini_app.dart';

/// Failure modes the Store / MyApps screens know how to render.
/// Free-form backend messages get mapped into one of these so the user
/// always sees a localized, actionable string — matches the convention
/// established by `AuthFailureReason` / `ProfileRepository`.
enum MiniAppFailureReason { network, server, unauthorized, unknown }

class MiniAppFailureException implements Exception {
  const MiniAppFailureException(this.reason);
  final MiniAppFailureReason reason;
  @override
  String toString() => 'MiniAppFailureException($reason)';
}

/// Boundary the state layer talks to. Only the *catalog* lives here —
/// install state is local-only and lives in [MiniAppInstallStorage].
/// Splitting them keeps the remote shape honest: the backend owns what
/// apps exist, the head-unit owns which of those the user has pinned.
///
/// Stub vs. api selection is a single line up in
/// `mini_app_repository_provider.dart`, mirroring auth/profile.
abstract class MiniAppRepository {
  const MiniAppRepository();

  /// Fetches the full catalog. Returns rows with `isInstalled: false` —
  /// the catalog controller merges install state from storage before
  /// the UI sees them.
  Future<List<MiniApp>> fetchCatalog({required CancelToken cancelToken});

  /// Synchronous-ish read of the last cached catalog. Returns null
  /// when there is no cache (first launch, sign-out, cache cleared,
  /// or this implementation does not persist anything — the default).
  /// Used by the catalog controller for instant Store-tab render
  /// while [fetchCatalog] revalidates in the background.
  ///
  /// Implementations that don't keep a local cache (e.g.
  /// [StubMiniAppRepository], unit-test fakes) can leave this as the
  /// default null-returning impl.
  Future<List<MiniApp>?> readCachedCatalog() async => null;
}

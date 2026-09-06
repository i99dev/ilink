import '../../kernel/shell/shell_command.dart';
import '../../kernel/shell/shell_ops_coordinator.dart';
import '../_car_domain/command/command_outcome.dart';
import 'app_launch_catalog.dart';

/// Routes an `app.*` voice command (+ args) to an `am start` on the car.
///
/// The `app_launcher` subagent (see [delegatingToolSpecs]) picks one of these
/// and this is its delegate's `domainDispatch` — analogous to
/// [dispatchRadioCommand], but the action is launching another Android app via
/// the existing shell bridge (`am start` / `monkey`) instead of an in-app
/// player. Nothing here touches the daemon car-command path; these are pure
/// app launches.
///
///   * `app.open`     `{app}`              → launch the app (no query)
///   * `app.search`   `{app, query}`       → open the app on a search/play query
///   * `app.navigate` `{destination, app}` → open a maps app navigating there
///
/// Returns the wire map the voice tool-result expects: `{ok: true, ...}` or
/// `{error: <message>}`. Never throws — a daemon failure or a missing app
/// becomes a spoken error, not a silent no-op.
Future<Map<String, dynamic>> dispatchAppCommand(
  ShellOpsCoordinator coord,
  String commandId,
  Map<String, dynamic> args,
) async {
  final outcome = switch (commandId) {
    'app.open' => await _open(coord, (args['app'] ?? '').toString()),
    'app.search' => await _search(
      coord,
      (args['app'] ?? '').toString(),
      (args['query'] ?? '').toString(),
    ),
    'app.navigate' => await _navigate(
      coord,
      (args['destination'] ?? '').toString(),
      (args['app'] ?? '').toString(),
    ),
    _ => CommandOutcome.failure('unknown app command: $commandId'),
  };
  return outcome.toJson();
}

/// Open an app by spoken name. Catalog first (the curated big apps), then a
/// best-effort match against installed packages so "open anything" works.
Future<CommandOutcome> _open(ShellOpsCoordinator coord, String app) async {
  if (app.trim().isEmpty) return CommandOutcome.failure('no app named');
  final spec = resolveAppSpec(app);
  if (spec != null) {
    return _run(coord, launcherArgv(spec.package), opened: spec.displayName);
  }
  final pkg = await _resolveInstalledPackage(coord, app);
  if (pkg == null) {
    return CommandOutcome.failure('couldn\'t find an app called "$app"');
  }
  return _run(coord, launcherArgv(pkg), opened: app);
}

/// Open an app on a search/play query (e.g. "play jazz on YouTube").
Future<CommandOutcome> _search(
  ShellOpsCoordinator coord,
  String app,
  String query,
) async {
  final spec = resolveAppSpec(app);
  if (spec == null) {
    // Unknown app → fall back to a plain launch if we can find the package.
    return _open(coord, app);
  }
  final q = query.trim();
  if (q.isEmpty || spec.searchUri == null) {
    // No query (or the app has no search deep link) → just launch it.
    return _run(coord, launcherArgv(spec.package), opened: spec.displayName);
  }
  return _run(
    coord,
    viewIntentArgv(fillUri(spec.searchUri!, q), package: spec.package),
    opened: '${spec.displayName} · $q',
  );
}

/// Open a maps app navigating to [destination]. [app] is optional — defaults
/// to the catalog's maps entry. "home"/"work" are passed through verbatim so
/// the maps app resolves them against the driver's own saved places.
Future<CommandOutcome> _navigate(
  ShellOpsCoordinator coord,
  String destination,
  String app,
) async {
  final dest = destination.trim();
  if (dest.isEmpty) return CommandOutcome.failure('no destination given');
  final spec =
      resolveAppSpec(app.isEmpty ? 'maps' : app) ?? resolveAppSpec('maps');
  if (spec?.navUri == null) {
    return CommandOutcome.failure('no navigation app available');
  }
  return _run(
    coord,
    viewIntentArgv(fillUri(spec!.navUri!, dest), package: spec.package),
    opened: 'directions to $dest',
  );
}

/// Run an `am start` / `monkey` argv and classify the result. `am` prints
/// "Error: ..." / "unable to resolve" to stdout (exit 0) when an app is
/// missing, so we inspect the text in addition to catching exceptions.
Future<CommandOutcome> _run(
  ShellOpsCoordinator coord,
  List<String> argv, {
  required String opened,
}) async {
  try {
    final out = await coord.write(
      ShellCommand(argv),
      coalesceKey: 'applaunch:${argv.join(' ')}',
    );
    final lower = out.toLowerCase();
    if (lower.contains('error:') ||
        lower.contains('unable to resolve') ||
        lower.contains('does not exist') ||
        lower.contains('no activities found')) {
      return CommandOutcome.failure('couldn\'t open $opened');
    }
    return CommandOutcome.success({'opened': opened});
  } catch (e) {
    return CommandOutcome.failure('couldn\'t open $opened ($e)');
  }
}

/// Generic name→package resolution via `pm list packages` (cached by the
/// coordinator). Reads ALL packages (system maps/media apps count too).
Future<String?> _resolveInstalledPackage(
  ShellOpsCoordinator coord,
  String app,
) async {
  try {
    final out = await coord.read(
      const ShellCommand([
        'pm',
        'list',
        'packages',
      ], cacheKey: 'pm list packages'),
    );
    final packages = [
      for (final line in out.split('\n'))
        if (line.trim().startsWith('package:')) line.trim().substring(8).trim(),
    ];
    return matchPackageByName(packages, app);
  } catch (_) {
    return null;
  }
}

/// Typed shell command. Always pass argv as a list — never a single
/// string — so spaces / quoting in package names or values can't open
/// a shell-injection vector. The bridge joins the list itself, with
/// shell-safe quoting applied per arg.
class ShellCommand {
  const ShellCommand(this.argv, {this.cacheKey, this.timeoutMs = 5000});

  /// argv[0] = binary (`pm`, `am`, `dumpsys`, `svc`, `settings`, `cmd`,
  /// …); argv[1..] = positional args. The bridge joins these with the
  /// minimum quoting required.
  final List<String> argv;

  /// When non-null, two callers asking for the same key within the
  /// bridge's coalesce window share one in-flight Future. Read paths
  /// usually set this to the canonical command string; write paths
  /// pass null (every write must execute).
  final String? cacheKey;

  /// Per-command timeout. Most diagnostic reads return in <100ms; we
  /// give them 5s headroom for an asleep daemon. Long commands (e.g.
  /// network scans) override.
  final int timeoutMs;

  /// Stable identity for breadcrumb logs — argv joined, with package
  /// names hashed by [ShellBreadcrumbFilter] before reaching Sentry.
  String get rawJoined => argv.join(' ');
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../kernel/access/adb_setup_state.dart';
import '../../../../kernel/config/config_provider.dart';
import '../../../../kernel/i18n/generated/app_localizations.dart';

/// Contextual overlay that explains the system "Allow USB debugging?"
/// prompt BEFORE it fires (or, more often, while the user is staring
/// at it wondering what triggered it). The system dialog wins z-order
/// — Android renders security prompts above all app windows — so this
/// card sits behind it, visible the moment the user dismisses or
/// confirms.
///
/// Mounted once at the app shell's Stack so it overlays every screen
/// (mini-apps, dashboards, settings) without each route needing to
/// opt in. Renders SizedBox.shrink in the steady-state idle/ready
/// case, so it's free to keep mounted.
///
/// English-only copy intentionally — sideloaded dev/installer build,
/// pre-translation.
/// TODO: localize when shipping to non-English-speaking technicians.
class DaemonSetupOverlay extends ConsumerWidget {
  const DaemonSetupOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Mock-car builds (emulator / web / dev without a Leopard head
    // unit) can never produce the "Allow USB debugging?" system
    // dialog because there's no adbd listening on 127.0.0.1:5555.
    // The Authorizing phase would otherwise sit on screen forever
    // waiting for a prompt that never arrives. Bypass entirely.
    if (ref.watch(appConfigBaseProvider).mockCar) {
      return const SizedBox.shrink();
    }
    // Once a setup succeeds, allow a genuine later failure to surface again by
    // clearing the dismissed flag.
    ref.listen(adbSetupStateProvider, (_, next) {
      if (next.value?.phase == AdbSetupPhase.ready) {
        ref.read(daemonSetupFailedDismissedProvider.notifier).set(false);
      }
    });
    final asyncSnap = ref.watch(adbSetupStateProvider);
    final snapshot = asyncSnap.maybeWhen(
      data: (s) => s,
      orElse: () => const AdbSetupSnapshot.idle(),
    );
    if (!snapshot.isOverlayVisible) return const SizedBox.shrink();
    // The user dismissed a setup failure this session → stay quiet through the
    // bring-up's forever-retry cycle (spawning→failed→spawning…). The daemon is
    // optional for the Nav-HUD, so nagging on every cycle is pure noise on ROMs
    // where it can't spawn. Resurfaces only after a successful `ready` (above).
    if (ref.watch(daemonSetupFailedDismissedProvider) &&
        (snapshot.phase == AdbSetupPhase.failed ||
            snapshot.phase == AdbSetupPhase.spawning)) {
      return const SizedBox.shrink();
    }
    // ``authorizing`` used to render an explainer card ("One-time
    // setup — Android will ask to allow USB debugging…") sitting
    // behind the system prompt. UX feedback: the doubled dialog
    // (system on top of our card) felt confusing on cold start —
    // the system prompt is self-explanatory enough on its own.
    // We still let the underlying AdbBootstrap run; we just don't
    // wrap it in an explainer. ``failed`` and ``spawning`` phases
    // keep their cards because they ARE the only signal there.
    if (snapshot.phase == AdbSetupPhase.authorizing) {
      return const SizedBox.shrink();
    }
    return _OverlayBody(snapshot: snapshot);
  }
}

class _OverlayBody extends ConsumerStatefulWidget {
  const _OverlayBody({required this.snapshot});
  final AdbSetupSnapshot snapshot;

  @override
  ConsumerState<_OverlayBody> createState() => _OverlayBodyState();
}

class _OverlayBodyState extends ConsumerState<_OverlayBody> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await ref.read(adbSetupChannelProvider).retry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  void _dismiss() {
    // Sticky for the session: suppress the failed/spawning overlay so the
    // forever-retrying bring-up can't re-pop it (cleared on a successful
    // `ready`, or app restart). Then re-emit idle to hide it now.
    ref.read(daemonSetupFailedDismissedProvider.notifier).set(true);
    ref.invalidate(adbSetupStateProvider);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final phase = widget.snapshot.phase;
    return Positioned.fill(
      child: Material(
        type: MaterialType.transparency,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.55),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: _Card(
                  cs: cs,
                  phase: phase,
                  error: widget.snapshot.error,
                  retrying: _retrying,
                  onRetry: _retry,
                  onDismiss: _dismiss,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.cs,
    required this.phase,
    required this.error,
    required this.retrying,
    required this.onRetry,
    required this.onDismiss,
  });

  final ColorScheme cs;
  final AdbSetupPhase phase;
  final String? error;
  final bool retrying;
  final Future<void> Function() onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final (title, body) = _copyFor(phase, error);
    final showSpinner =
        phase == AdbSetupPhase.authorizing || phase == AdbSetupPhase.spawning;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                phase == AdbSetupPhase.failed
                    ? Icons.error_outline
                    : Icons.developer_mode,
                size: 22,
                color: phase == AdbSetupPhase.failed ? cs.error : cs.secondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            body,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: cs.onSurfaceVariant,
            ),
          ),
          if (showSpinner) ...[
            const SizedBox(height: 18),
            const Align(
              alignment: AlignmentDirectional.centerStart,
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          ],
          if (phase == AdbSetupPhase.failed) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: retrying ? null : onDismiss,
                  child: Text(S.of(context).actionDismiss),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: retrying ? null : onRetry,
                  icon: retrying
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 16),
                  label: Text(retrying ? 'Retrying…' : 'Try again'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static (String, String) _copyFor(AdbSetupPhase phase, String? error) {
    switch (phase) {
      case AdbSetupPhase.authorizing:
        return (
          'One-time setup',
          'Android will ask to allow USB debugging. Tick '
              "'Always allow from this computer', then tap ALLOW. "
              'This only happens once per session.',
        );
      case AdbSetupPhase.spawning:
        return ('Setting up', 'Starting ilink background services…');
      case AdbSetupPhase.failed:
        final detail = (error ?? 'Unknown error').trim();
        final truncated = detail.length > 200
            ? '${detail.substring(0, 200)}…'
            : detail;
        return (
          "Setup didn't complete",
          'Background services could not start.\n\n$truncated',
        );
      case AdbSetupPhase.idle:
      case AdbSetupPhase.ready:
        // Defensive fallback — the parent widget gates these out
        // before we reach here.
        return ('', '');
    }
  }
}

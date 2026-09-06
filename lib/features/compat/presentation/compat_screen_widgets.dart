part of 'compat_screen.dart';

// ────────────────────────────────────────────────────────────────────
// Reusable cards / widgets
// ────────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _ProbeBlock extends StatelessWidget {
  const _ProbeBlock({required this.title, this.map, this.trailing});
  final String title;
  final Map<String, dynamic>? map;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final entries = map?.entries.toList() ?? const [];
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 4),
          if (map == null)
            Text(
              'pending…',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
            )
          else if (entries.isEmpty)
            Text(
              '(empty)',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
            )
          else
            ...entries.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 140,
                      child: Text(
                        e.key,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${e.value}',
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.title);
  final String title;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(
        title,
        style: TextStyle(
          color: cs.onSurface,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ActionRow extends StatefulWidget {
  const _ActionRow({
    required this.spec,
    required this.outcome,
    required this.busy,
    required this.onRun,
  });

  final _ActionSpec spec;
  final _Outcome? outcome;
  final bool busy;
  final void Function(Map<String, dynamic>) onRun;

  @override
  State<_ActionRow> createState() => _ActionRowState();
}

class _ActionRowState extends State<_ActionRow> {
  late final TextEditingController _controller;
  bool _toggle = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.spec.kind == _Kind.intArg
          ? widget.spec.defaultValue.toString()
          : '',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.spec.id,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                ),
                if (widget.spec.hint.isNotEmpty)
                  Text(
                    widget.spec.hint,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10),
                  ),
                if (widget.outcome != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    widget.outcome!.detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(flex: 2, child: _argInput(cs)),
          const SizedBox(width: 8),
          if (widget.outcome != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: widget.outcome!.color.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                widget.outcome!.label,
                style: TextStyle(
                  color: widget.outcome!.color,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          const SizedBox(width: 6),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(60, 32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              backgroundColor: AppColors.accent,
            ),
            onPressed: widget.busy ? null : _onRun,
            child: const Text('Run'),
          ),
        ],
      ),
    );
  }

  Widget _argInput(ColorScheme cs) {
    switch (widget.spec.kind) {
      case _Kind.tap:
        return Text(
          widget.spec.presetArgs.isEmpty
              ? '—'
              : widget.spec.presetArgs.toString(),
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
          textAlign: TextAlign.right,
        );
      case _Kind.intArg:
        return TextField(
          controller: _controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: TextStyle(color: cs.onSurface, fontSize: 12),
          decoration: InputDecoration(
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 6,
            ),
            hintText: widget.spec.argName,
          ),
        );
      case _Kind.boolArg:
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              _toggle ? 'on' : 'off',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
            ),
            Switch(
              value: _toggle,
              onChanged: (v) => setState(() => _toggle = v),
            ),
          ],
        );
    }
  }

  void _onRun() {
    Map<String, dynamic> args;
    switch (widget.spec.kind) {
      case _Kind.tap:
        args = Map<String, dynamic>.from(widget.spec.presetArgs);
        break;
      case _Kind.intArg:
        final parsed =
            int.tryParse(_controller.text) ?? widget.spec.defaultValue;
        args = {widget.spec.argName: parsed};
        break;
      case _Kind.boolArg:
        args = {widget.spec.argName: _toggle};
        break;
    }
    widget.onRun(args);
  }
}

class _BinderRow extends StatelessWidget {
  const _BinderRow({
    required this.probe,
    required this.outcome,
    required this.busy,
    required this.onRun,
  });
  final _BinderProbe probe;
  final _Outcome? outcome;
  final bool busy;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  probe.label,
                  style: TextStyle(color: cs.onSurface, fontSize: 13),
                ),
                Text(
                  '${probe.service}.${probe.method}  ${probe.args}',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
                if (outcome != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    outcome!.detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (outcome != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: outcome!.color.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                outcome!.label,
                style: TextStyle(
                  color: outcome!.color,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          const SizedBox(width: 6),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(60, 32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              backgroundColor: AppColors.secondary,
            ),
            onPressed: busy ? null : onRun,
            child: const Text('Run'),
          ),
        ],
      ),
    );
  }
}

class _BenchSummary extends StatelessWidget {
  const _BenchSummary({required this.summary});
  final ({int ok, int fail, int err, int total}) summary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = S.of(context);
    return Row(
      children: [
        _pill(t.compatBenchOk, summary.ok, AppColors.accent),
        const SizedBox(width: 6),
        _pill(t.compatBenchFail, summary.fail, AppColors.warning),
        const SizedBox(width: 6),
        _pill(t.compatBenchErr, summary.err, AppColors.primary),
        const SizedBox(width: 8),
        Text(
          t.compatBenchTotal(summary.total),
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
        ),
      ],
    );
  }

  Widget _pill(String label, int value, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withAlpha(40),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      '$label $value',
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
}

class _PendingChip extends StatelessWidget {
  const _PendingChip({required this.count});
  final int count;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$count reports saved on this device',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.save_outlined, size: 14, color: AppColors.warning),
            const SizedBox(width: 4),
            Text(
              '$count',
              style: const TextStyle(
                color: AppColors.warning,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

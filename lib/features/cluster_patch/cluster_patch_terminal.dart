import 'dart:async';

import 'package:flutter/material.dart';

/// Which operation the terminal is narrating — selects the scripted steps
/// and the prompt line.
enum PatchTerminalMode { patch, undo }

/// A faux-hacker terminal that streams the pipeline steps while the real
/// operation ([run]) runs underneath, then prints the actual result line
/// produced by [summarize]. Returns the real result when the user closes
/// it (or null if [run] threw).
///
/// Generic over the result type [R] so the SAME UI drives both patch
/// ([PatchOutcome]) and undo ([UnpatchOutcome]).
Future<R?> showClusterPatchTerminal<R>({
  required BuildContext context,
  required PatchTerminalMode mode,
  required String packageName,
  required String label,
  required Future<R> Function() run,
  required ({bool ok, String line}) Function(R result) summarize,
}) {
  return showDialog<R>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _Terminal<R>(
      mode: mode,
      packageName: packageName,
      label: label,
      run: run,
      summarize: summarize,
    ),
  );
}

enum _Kind { cmd, dim, ok, err, info }

class _Line {
  const _Line(this.text, this.kind);
  final String text;
  final _Kind kind;
}

class _Terminal<R> extends StatefulWidget {
  const _Terminal({
    required this.mode,
    required this.packageName,
    required this.label,
    required this.run,
    required this.summarize,
  });

  final PatchTerminalMode mode;
  final String packageName;
  final String label;
  final Future<R> Function() run;
  final ({bool ok, String line}) Function(R) summarize;

  @override
  State<_Terminal<R>> createState() => _TerminalState<R>();
}

class _TerminalState<R> extends State<_Terminal<R>> {
  static const _bg = Color(0xFF0A0E0A);
  static const _cmd = Color(0xFFB9F6CA);
  static const _dim = Color(0xFF5FAE5F);
  static const _ok = Color(0xFF39FF14);
  static const _err = Color(0xFFFF5252);
  static const _info = Color(0xFF4DD0E1);

  final _lines = <_Line>[];
  final _scroll = ScrollController();
  late final List<_Line> _script;
  int _idx = 0;
  Timer? _ticker;
  Timer? _cursor;
  bool _cursorOn = true;
  bool _done = false;
  R? _result;

  @override
  void initState() {
    super.initState();
    _script = _buildScript(widget.mode, widget.packageName);
    _cursor = Timer.periodic(const Duration(milliseconds: 480), (_) {
      if (mounted) setState(() => _cursorOn = !_cursorOn);
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted) return;
      if (_idx < _script.length) {
        setState(() => _lines.add(_script[_idx++]));
        _scrollToEnd();
      }
    });
    _runOp();
  }

  Future<void> _runOp() async {
    R? result;
    ({bool ok, String line}) summary;
    try {
      result = await widget.run();
      summary = widget.summarize(result as R);
    } catch (e) {
      result = null;
      summary = (ok: false, line: '[✗] FAILED: $e');
    }
    if (!mounted) return;
    setState(() {
      while (_idx < _script.length) {
        _lines.add(_script[_idx++]); // flush remaining scripted steps
      }
      _lines.add(_Line(summary.line, summary.ok ? _Kind.ok : _Kind.err));
      _result = result;
      _done = true;
    });
    _ticker?.cancel();
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _cursor?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Color _colorFor(_Kind k) => switch (k) {
    _Kind.cmd => _cmd,
    _Kind.dim => _dim,
    _Kind.ok => _ok,
    _Kind.err => _err,
    _Kind.info => _info,
  };

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _bg,
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFF1E2A1A)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _titleBar(),
            Flexible(
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final l in _lines)
                      Text(
                        l.text,
                        style: TextStyle(
                          color: _colorFor(l.kind),
                          fontFamily: 'monospace',
                          fontSize: 12.5,
                          height: 1.4,
                        ),
                      ),
                    if (!_done)
                      Text(
                        _cursorOn ? '# ▌' : '#',
                        style: const TextStyle(
                          color: _ok,
                          fontFamily: 'monospace',
                          fontSize: 12.5,
                          height: 1.4,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _titleBar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: const BoxDecoration(
      color: Color(0xFF11160F),
      border: Border(bottom: BorderSide(color: Color(0xFF1E2A1A))),
    ),
    child: Row(
      children: [
        _dot(const Color(0xFFFF5F56)),
        const SizedBox(width: 6),
        _dot(const Color(0xFFFFBD2E)),
        const SizedBox(width: 6),
        _dot(const Color(0xFF27C93F)),
        const SizedBox(width: 12),
        Text(
          widget.mode == PatchTerminalMode.undo
              ? 'cluster-patch — restore'
              : 'cluster-patch — privileged shell',
          style: const TextStyle(
            color: Color(0xFF8FB98F),
            fontFamily: 'monospace',
            fontSize: 12,
          ),
        ),
      ],
    ),
  );

  Widget _dot(Color c) => Container(
    width: 11,
    height: 11,
    decoration: BoxDecoration(color: c, shape: BoxShape.circle),
  );

  Widget _footer() => Container(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: Color(0xFF1E2A1A))),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (!_done)
          const Text(
            'working…',
            style: TextStyle(
              color: _dim,
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          )
        else
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1B5E20),
              foregroundColor: _ok,
            ),
            onPressed: () => Navigator.of(context).pop(_result),
            child: const Text('Close'),
          ),
      ],
    ),
  );
}

List<_Line> _buildScript(PatchTerminalMode mode, String pkg) =>
    mode == PatchTerminalMode.undo
    ? [
        _Line('ilink@cluster ~ # ./unpatch --restore $pkg', _Kind.cmd),
        const _Line(
          '[*] acquiring privileged adb bridge … ok (uid=shell)',
          _Kind.dim,
        ),
        const _Line('[*] locating original backup …', _Kind.dim),
        const _Line('[*] reading original base.apk + splits', _Kind.dim),
        const _Line('[*] staging original → /data/local/tmp', _Kind.dim),
        _Line('[*] pm uninstall $pkg (patched)', _Kind.dim),
        const _Line('[*] pm install-create -t -r', _Kind.dim),
        const _Line('[*] pm install-write … --streamed', _Kind.dim),
        const _Line('[*] pm install-commit', _Kind.dim),
        const _Line('[*] verifying original signer …', _Kind.dim),
      ]
    : [
        _Line('ilink@cluster ~ # ./patch --target $pkg', _Kind.cmd),
        const _Line(
          '[*] acquiring privileged adb bridge … ok (uid=shell)',
          _Kind.dim,
        ),
        _Line('[*] resolving package … $pkg', _Kind.dim),
        const _Line('[*] pulling base.apk + config splits', _Kind.dim),
        const _Line('[*] parsing binary AndroidManifest.xml (AXML)', _Kind.dim),
        const _Line(
          '[+] inject  android:resizeableActivity = true',
          _Kind.info,
        ),
        const _Line(
          '[+] inject  <meta-data BYD_SUPPORT_SPLIT_ACTIVITY=1>',
          _Kind.info,
        ),
        const _Line('[+] set     android:extractNativeLibs = true', _Kind.info),
        const _Line(
          '[*] zipalign + re-sign  (apksig v2 · RSA-2048)',
          _Kind.dim,
        ),
        const _Line('[*] staging payload → /data/local/tmp', _Kind.dim),
        _Line('[*] pm uninstall $pkg', _Kind.dim),
        const _Line('[*] pm install-create -t -r', _Kind.dim),
        const _Line('[*] pm install-write -S … --streamed', _Kind.dim),
        const _Line('[*] pm install-commit', _Kind.dim),
        const _Line('[*] verifying signer + cluster flags …', _Kind.dim),
      ];

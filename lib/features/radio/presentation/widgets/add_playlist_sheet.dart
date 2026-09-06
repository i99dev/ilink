import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/_car_domain/command/command_outcome.dart';
import '../../../../kernel/ui/theme/colors.dart';
import '../../providers.dart';

/// Modal bottom sheet for adding a user playlist — from a local
/// `.m3u`/`.m3u8` file or from a URL.
///
/// Returns the newly-created playlist id on success, `null` if the user
/// dismissed without importing. Errors land as inline SnackBars so the
/// sheet stays open for retry; the caller never has to re-show on
/// failure.
class AddPlaylistSheet extends ConsumerStatefulWidget {
  const AddPlaylistSheet({super.key});

  static Future<String?> show(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const AddPlaylistSheet(),
    );
  }

  @override
  ConsumerState<AddPlaylistSheet> createState() => _AddPlaylistSheetState();
}

class _AddPlaylistSheetState extends ConsumerState<AddPlaylistSheet> {
  final _nameCtl = TextEditingController();
  final _urlCtl = TextEditingController();
  File? _pickedFile;
  bool _busy = false;

  @override
  void dispose() {
    _nameCtl.dispose();
    _urlCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + inset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _grabber(cs),
            const SizedBox(height: 4),
            Text(
              'ADD PLAYLIST',
              style: TextStyle(
                letterSpacing: 3,
                fontSize: 12,
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
            _nameField(cs),
            const SizedBox(height: 12),
            _fileRow(cs),
            const SizedBox(height: 12),
            _urlField(cs),
            const SizedBox(height: 16),
            if (_busy) const LinearProgressIndicator(),
            if (!_busy) _importButtons(cs),
          ],
        ),
      ),
    );
  }

  Widget _grabber(ColorScheme cs) => Center(
    child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      height: 4,
      width: 44,
      decoration: BoxDecoration(
        color: cs.outlineVariant,
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );

  Widget _nameField(ColorScheme cs) => TextField(
    key: const Key('add_playlist.name'),
    controller: _nameCtl,
    enabled: !_busy,
    textInputAction: TextInputAction.next,
    decoration: InputDecoration(
      labelText: 'Name',
      hintText: 'e.g. My Arabic Radio',
      filled: true,
      fillColor: cs.surfaceContainer,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    ),
  );

  Widget _fileRow(ColorScheme cs) => Row(
    children: [
      Expanded(
        child: Text(
          _pickedFile == null
              ? 'No file selected'
              : _pickedFile!.path.split(RegExp(r'[\\/]')).last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
        ),
      ),
      const SizedBox(width: 8),
      OutlinedButton.icon(
        key: const Key('add_playlist.pick_file'),
        onPressed: _busy ? null : _pickFile,
        icon: const Icon(Icons.folder_open_rounded, size: 18),
        label: const Text('Browse'),
      ),
    ],
  );

  Widget _urlField(ColorScheme cs) => TextField(
    key: const Key('add_playlist.url'),
    controller: _urlCtl,
    enabled: !_busy,
    keyboardType: TextInputType.url,
    decoration: InputDecoration(
      labelText: 'or paste an M3U URL',
      hintText: 'https://example.com/list.m3u',
      filled: true,
      fillColor: cs.surfaceContainer,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    ),
  );

  Widget _importButtons(ColorScheme cs) => Row(
    children: [
      Expanded(
        child: OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: FilledButton.icon(
          key: const Key('add_playlist.submit'),
          style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
          onPressed: _canImport ? _import : null,
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('Import'),
        ),
      ),
    ],
  );

  bool get _canImport {
    if (_nameCtl.text.trim().isEmpty) return false;
    return _pickedFile != null || _urlCtl.text.trim().isNotEmpty;
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['m3u', 'm3u8'],
      withData: false,
    );
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() {
      _pickedFile = File(path);
      // Auto-fill the name from the filename if the user hasn't typed
      // one yet — saves a keystroke on a head-unit keyboard.
      if (_nameCtl.text.trim().isEmpty) {
        final tail = path.split(RegExp(r'[\\/]')).last;
        final dot = tail.lastIndexOf('.');
        _nameCtl.text = dot > 0 ? tail.substring(0, dot) : tail;
      }
    });
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ctrl = ref.read(userPlaylistControllerProvider.notifier);
    final name = _nameCtl.text.trim();
    final url = _urlCtl.text.trim();
    final file = _pickedFile;
    final CommandOutcome out;
    // URL wins when both are set — the file likely came from auto-fill
    // and the user pasted a URL afterwards.
    if (url.isNotEmpty) {
      out = await ctrl.addFromUrl(url, name: name);
    } else if (file != null) {
      out = await ctrl.addFromFile(file, name: name);
    } else {
      setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    if (out.ok) {
      final id = (out.data?['id'] as String?) ?? '';
      Navigator.of(context).pop(id.isEmpty ? null : id);
    } else {
      setState(() => _busy = false);
      messenger?.showSnackBar(
        SnackBar(content: Text(out.message ?? 'Import failed')),
      );
    }
  }
}

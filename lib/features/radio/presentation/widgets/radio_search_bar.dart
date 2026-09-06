import 'dart:async';

import 'package:flutter/material.dart';

/// Debounced search field. Fires [onChanged] 300 ms after typing stops so
/// we don't fire a GET for every keystroke — backend has its own 60 s
/// cache but the burst still eats bandwidth on cellular.
class RadioSearchBar extends StatefulWidget {
  const RadioSearchBar({
    super.key,
    required this.onChanged,
    this.hint = 'Search stations',
  });

  final ValueChanged<String> onChanged;
  final String hint;

  @override
  State<RadioSearchBar> createState() => _RadioSearchBarState();
}

class _RadioSearchBarState extends State<RadioSearchBar> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;

  static const _debounceDuration = Duration(milliseconds: 300);

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDuration, () => widget.onChanged(value));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TextField(
      controller: _controller,
      onChanged: _onTextChanged,
      style: TextStyle(color: cs.onSurface, fontSize: 14),
      decoration: InputDecoration(
        filled: true,
        fillColor: cs.surfaceContainer,
        hintText: widget.hint,
        hintStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
        prefixIcon: Icon(Icons.search_rounded, color: cs.onSurfaceVariant),
        suffixIcon: _controller.text.isEmpty
            ? null
            : IconButton(
                icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant),
                onPressed: () {
                  _controller.clear();
                  _debounce?.cancel();
                  widget.onChanged('');
                },
              ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
    );
  }
}

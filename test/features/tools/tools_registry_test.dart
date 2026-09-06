import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/tools/domain/tool.dart';
import 'package:ilink/features/tools/registry/tools_registry.dart';

/// The Tools strip iterates [kToolsRegistry] — corruption (missing
/// label, duplicate kind) would silently surface as a blank circle
/// at runtime. Catch it at build time instead.
void main() {
  group('kToolsRegistry', () {
    test('every entry has a non-empty labelKey', () {
      for (final tool in kToolsRegistry) {
        expect(
          tool.labelKey.isNotEmpty,
          isTrue,
          reason: 'tool ${tool.kind} has empty labelKey',
        );
      }
    });

    test('no duplicate ToolKind', () {
      final kinds = kToolsRegistry.map((t) => t.kind).toList();
      expect(kinds.toSet().length, kinds.length);
    });

    test('Network is present (Phase 1 contract)', () {
      expect(kToolsRegistry.any((t) => t.kind == ToolKind.network), isTrue);
    });
  });
}

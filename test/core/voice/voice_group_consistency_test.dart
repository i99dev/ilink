import 'package:ilink/features/_car_domain/command/command.dart';
import 'package:ilink/features/_car_domain/command/registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every command that opts into a `voiceGroup` must agree with its peers on
/// the group-level fields: voiceIdTemplate, voiceGroupParams, and
/// voiceDescription. The manifest builder uses the first member's values
/// and silently ignores the others, so divergence would be a subtle bug
/// that only surfaces in production voice manifests — this test fires it
/// at CI time instead.
///
/// Also enforces: every voiceIdTemplate placeholder must be a key in
/// voiceGroupParams (a template like `window.{window}.{action}` referring
/// to an arg key that doesn't exist would always render empty and hit the
/// "unresolved group call" branch).
void main() {
  final byGroup = <String, List<CarCommand>>{};
  for (final cmd in commandRegistry.values) {
    if (cmd.voiceHidden) continue;
    final g = cmd.voiceGroup;
    if (g != null) byGroup.putIfAbsent(g, () => []).add(cmd);
  }

  group('group metadata consistency', () {
    for (final entry in byGroup.entries) {
      final group = entry.key;
      final members = entry.value;
      test('$group members agree on voiceIdTemplate', () {
        final templates = members.map((c) => c.voiceIdTemplate).toSet();
        expect(
          templates,
          hasLength(1),
          reason: '$group has divergent voiceIdTemplate: $templates',
        );
      });

      test('$group members agree on voiceGroupParams', () {
        final encoded = members
            .map(
              (c) => c.voiceGroupParams?.entries
                  .map((e) => '${e.key}=${e.value}')
                  .join(','),
            )
            .toSet();
        expect(
          encoded,
          hasLength(1),
          reason: '$group has divergent voiceGroupParams: $encoded',
        );
      });

      test('$group members agree on voiceDescription', () {
        final desc = members.map((c) => c.voiceDescription).toSet();
        expect(
          desc,
          hasLength(1),
          reason: '$group has divergent voiceDescription: $desc',
        );
      });
    }
  });

  group('template placeholders resolve to voiceGroupParams keys', () {
    final placeholderRe = RegExp(r'\{(\w+)\}');
    for (final entry in byGroup.entries) {
      final group = entry.key;
      final head = entry.value.first;
      test(group, () {
        final placeholders = placeholderRe
            .allMatches(head.voiceIdTemplate!)
            .map((m) => m.group(1)!)
            .toSet();
        final paramKeys = head.voiceGroupParams!.keys.toSet();
        // Every placeholder must be a param key. Extra param keys (that
        // aren't placeholders) are fine — they're discriminators the
        // dispatch closure consumes rather than the template.
        final missing = placeholders.difference(paramKeys);
        expect(
          missing,
          isEmpty,
          reason:
              '$group template references ${missing.toList()} which are '
              'not in voiceGroupParams keys ${paramKeys.toList()}',
        );
      });
    }
  });

  group(
    'every rendered template for a group member resolves to a registry id',
    () {
      final placeholderRe = RegExp(r'\{(\w+)\}');
      for (final entry in byGroup.entries) {
        final group = entry.key;
        final members = entry.value;
        test(group, () {
          final head = members.first;
          final placeholders = placeholderRe
              .allMatches(head.voiceIdTemplate!)
              .map((m) => m.group(1)!)
              .toList();

          // For each member, back-derive the placeholder values from its id
          // (by matching the template against the id) and re-render to check
          // round-trip. This catches, e.g., a command id like
          // `seat.heat.drv` that got tagged with a template `seat.heat.{seat}`
          // when `{seat}` isn't in the id's third segment.
          for (final member in members) {
            // Build a regex from the template by replacing {x} with a named capture group.
            final pattern = head.voiceIdTemplate!.replaceAllMapped(
              placeholderRe,
              (m) => '(?<${m.group(1)}>[^.]+)',
            );
            final match = RegExp('^$pattern\$').firstMatch(member.id);
            expect(
              match,
              isNotNull,
              reason:
                  '$group: member id "${member.id}" does not match template '
                  '"${head.voiceIdTemplate}"',
            );
            // And re-rendering with extracted values reproduces the id.
            final args = <String, dynamic>{
              for (final p in placeholders) p: match!.namedGroup(p)!,
            };
            final rendered = head.voiceIdTemplate!.replaceAllMapped(
              placeholderRe,
              (m) => args[m.group(1)!].toString(),
            );
            expect(rendered, member.id);
          }
        });
      }
    },
  );
}

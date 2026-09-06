import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/kernel/registry/action_def.dart';
import 'package:ilink/features/app_actions/domain/app_action.dart';
import 'package:ilink/features/app_actions/registry/app_actions_registry.dart';

/// Build-time gate: every registry entry must satisfy [validateActionDef]
/// and use a known action id. A typo in the registry fails this test
/// before the build ships — much louder than a runtime fall-through to
/// the raw l10n key.
void main() {
  group('kAppActionsRegistry', () {
    test('every entry passes validateActionDef', () {
      for (final def in kAppActionsRegistry) {
        final problem = validateActionDef(def);
        expect(
          problem,
          isNull,
          reason: 'invalid registry entry: ${def.id}: $problem',
        );
      }
    });

    test('every id maps to an AppActionKind', () {
      final knownIds = AppActionKind.values.map((k) => k.name).toSet();
      for (final def in kAppActionsRegistry) {
        expect(
          knownIds.contains(def.id),
          isTrue,
          reason: 'registry id ${def.id} has no matching AppActionKind',
        );
      }
    });

    test('all 7 actions are present (matches Saqr parity claim)', () {
      final ids = kAppActionsRegistry.map((d) => d.id).toSet();
      expect(ids, hasLength(AppActionKind.values.length));
      expect(ids, containsAll(AppActionKind.values.map((k) => k.name)));
    });

    test('typedConfirm entries have non-empty token + body key', () {
      for (final def in kAppActionsRegistry) {
        if (def.severity != ActionSeverity.typedConfirm) continue;
        expect(def.typedToken, isNotNull);
        expect(def.typedToken!.isNotEmpty, isTrue);
        expect(def.confirmKey, isNotNull);
      }
    });

    test('confirm severity entries have body key', () {
      for (final def in kAppActionsRegistry) {
        if (def.severity != ActionSeverity.confirm) continue;
        expect(def.confirmKey, isNotNull);
      }
    });

    test('safe severity entries do not declare typedToken', () {
      for (final def in kAppActionsRegistry) {
        if (def.severity != ActionSeverity.safe) continue;
        expect(def.typedToken, isNull);
      }
    });
  });
}

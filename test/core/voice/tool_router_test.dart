import 'package:ilink/features/voice/state/tool_router.dart';
import 'package:flutter_test/flutter_test.dart';

/// CompositeToolRouter is the Phase-2 seam for plugging future domains
/// (Nav, Media) in without modifying the voice controller. These tests pin
/// the routing + describe() contracts it exposes.
void main() {
  group('CompositeToolRouter', () {
    test('dispatch forwards to the first router that handles the id', () async {
      final carRouter = _FakeRouter(ns: 'car', ids: {'door.lock', 'ac.power'});
      final navRouter = _FakeRouter(ns: 'nav', ids: {'nav.goto'});
      final composite = CompositeToolRouter([carRouter, navRouter]);

      final r = await composite.dispatch('door.lock', const {'force': true});
      expect(r, {'router': 'car', 'id': 'door.lock'});
      expect(carRouter.calls, [
        [
          'door.lock',
          const {'force': true},
        ],
      ]);
      expect(navRouter.calls, isEmpty);
    });

    test('unknown id returns uniform {error: ...}', () async {
      final composite = CompositeToolRouter([
        _FakeRouter(ns: 'car', ids: {'door.lock'}),
      ]);
      final r = await composite.dispatch('unknown.one', const {});
      expect(r['error'], contains('unknown command'));
    });

    test('handles() is true iff any child claims the id', () {
      final composite = CompositeToolRouter([
        _FakeRouter(ns: 'car', ids: {'door.lock'}),
        _FakeRouter(ns: 'nav', ids: {'nav.goto'}),
      ]);
      expect(composite.handles('door.lock'), isTrue);
      expect(composite.handles('nav.goto'), isTrue);
      expect(composite.handles('something.else'), isFalse);
    });

    test('describe() concatenates entries from every child in order', () {
      final composite = CompositeToolRouter([
        _FakeRouter(ns: 'car', ids: {'door.lock'}, describeTag: 'c'),
        _FakeRouter(ns: 'nav', ids: {'nav.goto'}, describeTag: 'n'),
      ]);
      final d = composite.describe();
      expect(d, [
        {'id': 'door.lock', 'tag': 'c'},
        {'id': 'nav.goto', 'tag': 'n'},
      ]);
    });

    test('earliest-registered router wins on id overlap', () async {
      final first = _FakeRouter(ns: 'a', ids: {'shared'});
      final second = _FakeRouter(ns: 'b', ids: {'shared'});
      final composite = CompositeToolRouter([first, second]);
      await composite.dispatch('shared', const {});
      expect(first.calls, isNotEmpty);
      expect(second.calls, isEmpty);
    });
  });
}

class _FakeRouter implements ToolRouter {
  _FakeRouter({required this.ns, required this.ids, this.describeTag});
  final String ns;
  final Set<String> ids;
  final String? describeTag;
  final List<List<dynamic>> calls = [];

  @override
  String get namespace => ns;

  @override
  bool handles(String commandId) => ids.contains(commandId);

  @override
  List<Map<String, dynamic>> describe() => [
    for (final id in ids)
      {'id': id, if (describeTag != null) 'tag': describeTag},
  ];

  @override
  List<Map<String, dynamic>> manifestEntries() => const [];

  @override
  Future<Map<String, dynamic>> dispatch(
    String commandId,
    Map<String, dynamic> args,
  ) async {
    calls.add([commandId, args]);
    return {'router': ns, 'id': commandId};
  }
}

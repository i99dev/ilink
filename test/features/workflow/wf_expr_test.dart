import 'package:flutter_test/flutter_test.dart';
import 'package:ilink/features/workflow/engine/wf_expr.dart';

void main() {
  // Resolver: bare names → a fixed signal table; `$x` → a var table.
  num? resolve(String token) {
    const signals = {
      'battery_pct': 40,
      'Statistic.SPEED': 0,
      'ambient_lux': 800,
    };
    const vars = {r'$base': 20, r'$gone': null};
    if (token.startsWith(r'$')) return vars[token];
    return signals[token];
  }

  num? evalSrc(String src) => WfExpr.tryParse(src)?.eval(resolve);

  group('WfExpr.tryParse (fail-closed)', () {
    test('parses arithmetic with precedence + parens', () {
      expect(evalSrc('2 + 3 * 4'), 14);
      expect(evalSrc('(2 + 3) * 4'), 20);
      expect(evalSrc('10 / 4'), 2.5);
    });

    test(r'resolves signal names (incl. dotted) and $vars', () {
      expect(evalSrc('battery_pct - 10'), 30);
      expect(evalSrc('ambient_lux / 100'), 8);
      expect(evalSrc(r'$base + 2'), 22);
    });

    test('unary minus', () {
      expect(evalSrc('-5 + 8'), 3);
      expect(evalSrc('battery_pct * -1'), -40);
    });

    test('null-propagates on an unknown operand', () {
      expect(evalSrc('unknown_signal + 1'), isNull);
      expect(evalSrc(r'$gone + 1'), isNull); // var present but null
      expect(evalSrc(r'$missing + 1'), isNull); // var absent
    });

    test('divide-by-zero → null (never throws)', () {
      expect(evalSrc('5 / 0'), isNull);
      expect(evalSrc('5 / (battery_pct - 40)'), isNull); // /0 via expr
    });

    test('returns null for malformed input (fail-closed)', () {
      expect(WfExpr.tryParse('2 +'), isNull);
      expect(WfExpr.tryParse('(2 + 3'), isNull);
      expect(WfExpr.tryParse('2 ** 3'), isNull);
      expect(WfExpr.tryParse('drop table;'), isNull);
      expect(WfExpr.tryParse(''), isNull);
      expect(WfExpr.tryParse('   '), isNull);
    });

    test('rejects an over-long expression', () {
      expect(WfExpr.tryParse('1+' * 200), isNull);
    });
  });
}

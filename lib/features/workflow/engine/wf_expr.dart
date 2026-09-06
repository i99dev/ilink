/// A tiny, SAFE arithmetic expression evaluator for the `set_var` action.
///
/// Grammar (bounded, non-Turing-complete — same design rule as the whole
/// workflow document):
///
///     expr   := term (('+' | '-') term)*
///     term   := factor (('*' | '/') factor)*
///     factor := number | ref | '$' ident | '(' expr ')'
///     ref    := a catalog signal name (dotted identifier)
///
/// Operands resolve through a caller-supplied function: a bare identifier
/// is a CAN signal (read live), a `$name` is a workflow variable. There
/// are NO functions, NO comparisons, NO assignment — just `+ - * /` over
/// numbers. [tryParse] is FAIL-CLOSED: a malformed expression yields null
/// so the compiler refuses to arm rather than mis-evaluating. Evaluation
/// is null-propagating: any unknown operand (or divide-by-zero) makes the
/// whole expression null, and `set_var` then leaves the variable unset.
library;

/// A parsed, reusable expression. Built once at compile time.
class WfExpr {
  WfExpr._(this._root);

  final _Node _root;

  /// Parse [src] into an expression, or null if it's malformed.
  static WfExpr? tryParse(String src) {
    try {
      final tokens = _tokenize(src);
      if (tokens.isEmpty) return null;
      final parser = _Parser(tokens);
      final node = parser.parseExpr();
      if (!parser.atEnd) return null; // trailing junk → fail closed
      return WfExpr._(node);
    } catch (_) {
      return null;
    }
  }

  /// Evaluate. [resolve] returns the numeric value of an operand token
  /// (`$name` for a variable, else a signal name), or null if unknown.
  /// Returns null if any operand is null or a division by zero occurs.
  num? eval(num? Function(String token) resolve) => _root.eval(resolve);
}

// ── tokens ──────────────────────────────────────────────────────────

enum _Tk { num, ident, plus, minus, star, slash, lparen, rparen }

class _Token {
  const _Token(this.kind, [this.text = '', this.value = 0]);
  final _Tk kind;
  final String text;
  final num value;
}

const int _maxLen = 256;

List<_Token> _tokenize(String s) {
  if (s.length > _maxLen) throw const FormatException('too long');
  final out = <_Token>[];
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == ' ' || c == '\t') {
      i++;
      continue;
    }
    switch (c) {
      case '+':
        out.add(const _Token(_Tk.plus));
        i++;
        continue;
      case '-':
        out.add(const _Token(_Tk.minus));
        i++;
        continue;
      case '*':
        out.add(const _Token(_Tk.star));
        i++;
        continue;
      case '/':
        out.add(const _Token(_Tk.slash));
        i++;
        continue;
      case '(':
        out.add(const _Token(_Tk.lparen));
        i++;
        continue;
      case ')':
        out.add(const _Token(_Tk.rparen));
        i++;
        continue;
    }
    // number
    final numMatch = RegExp(r'^\d+(\.\d+)?').firstMatch(s.substring(i));
    if (numMatch != null) {
      final t = numMatch.group(0)!;
      out.add(_Token(_Tk.num, t, num.parse(t)));
      i += t.length;
      continue;
    }
    // identifier: optional leading `$`, then a dotted name.
    final idMatch = RegExp(
      r'^\$?[A-Za-z_][A-Za-z0-9_.]*',
    ).firstMatch(s.substring(i));
    if (idMatch != null) {
      final t = idMatch.group(0)!;
      out.add(_Token(_Tk.ident, t));
      i += t.length;
      continue;
    }
    throw FormatException('bad char "$c"');
  }
  return out;
}

// ── AST ─────────────────────────────────────────────────────────────

sealed class _Node {
  num? eval(num? Function(String) resolve);
}

class _Lit extends _Node {
  _Lit(this.v);
  final num v;
  @override
  num? eval(num? Function(String) resolve) => v;
}

class _Ref extends _Node {
  _Ref(this.token);
  final String token;
  @override
  num? eval(num? Function(String) resolve) => resolve(token);
}

class _Bin extends _Node {
  _Bin(this.op, this.l, this.r);
  final _Tk op;
  final _Node l;
  final _Node r;
  @override
  num? eval(num? Function(String) resolve) {
    final a = l.eval(resolve);
    final b = r.eval(resolve);
    if (a == null || b == null) return null;
    switch (op) {
      case _Tk.plus:
        return a + b;
      case _Tk.minus:
        return a - b;
      case _Tk.star:
        return a * b;
      case _Tk.slash:
        return b == 0 ? null : a / b;
      default:
        return null;
    }
  }
}

// ── recursive-descent parser ────────────────────────────────────────

class _Parser {
  _Parser(this._tokens);
  final List<_Token> _tokens;
  int _pos = 0;

  bool get atEnd => _pos >= _tokens.length;
  _Token get _peek => _tokens[_pos];

  _Node parseExpr() {
    var node = _parseTerm();
    while (!atEnd && (_peek.kind == _Tk.plus || _peek.kind == _Tk.minus)) {
      final op = _tokens[_pos++].kind;
      node = _Bin(op, node, _parseTerm());
    }
    return node;
  }

  _Node _parseTerm() {
    var node = _parseFactor();
    while (!atEnd && (_peek.kind == _Tk.star || _peek.kind == _Tk.slash)) {
      final op = _tokens[_pos++].kind;
      node = _Bin(op, node, _parseFactor());
    }
    return node;
  }

  _Node _parseFactor() {
    if (atEnd) throw const FormatException('unexpected end');
    final t = _tokens[_pos++];
    switch (t.kind) {
      case _Tk.num:
        return _Lit(t.value);
      case _Tk.ident:
        return _Ref(t.text);
      case _Tk.minus:
        // Unary minus: -factor  ⇒  0 - factor.
        return _Bin(_Tk.minus, _Lit(0), _parseFactor());
      case _Tk.lparen:
        final inner = parseExpr();
        if (atEnd || _tokens[_pos].kind != _Tk.rparen) {
          throw const FormatException('missing )');
        }
        _pos++; // consume ')'
        return inner;
      default:
        throw FormatException('unexpected ${t.kind}');
    }
  }
}

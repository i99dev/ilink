/// Generic command-template engine for privileged mini-app ops.
///
/// Phase-7 refactor: the old hardcoded ``AdminOpRegistry`` is gone.
/// Templates are now data — fetched from the server's catalog and
/// cached locally — not Dart constants. Adding a BYD-specific shell
/// command is a server migration row, not a Dart code change.
///
/// What stays in code is the *engine*:
///   * [AdminOpTier] enum (tier 1 read / tier 2 control)
///   * [CommandTemplate] data class
///   * [TemplateRegistry] in-memory store + lookup
///   * [validateParams] / [renderCommand] mirroring the backend's
///     ``app/domain/admin_perms/templates.py`` rules byte-for-byte.
///
/// The two implementations MUST agree on validation outcomes — a
/// disagreement either lets the device run something the server
/// rejected, or vice versa. Each side has its own test suite; when
/// either changes, both move together.
library;

/// Tier classification mirrors the backend's
/// ``permission_definitions.tier`` column.
enum AdminOpTier { tier1, tier2 }

/// One slot rule from a template's ``param_schema``. Three kinds —
/// matches the backend's validators.
sealed class ParamRule {
  const ParamRule();

  /// Validate [value] against this rule. Returns the (possibly
  /// coerced) value to use, or throws [TemplateValidationError]
  /// with a slot-qualified message.
  Object? validate(String slot, Object? value);

  /// JSON shape served to the mini-app via the bridge. Matches the
  /// SDK's `ParamRule` discriminated union in
  /// ``packages/admin-sdk/src/types.ts``. Round-trippable with
  /// [ParamRule.fromJson].
  Map<String, Object?> toMiniAppJson();

  factory ParamRule.fromJson(Map<String, Object?> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'int':
        return IntParamRule(
          min: (json['min'] as num?)?.toInt(),
          max: (json['max'] as num?)?.toInt(),
          defaultValue: (json['default'] as num?)?.toInt(),
        );
      case 'enum':
        return EnumParamRule(
          values: List<Object?>.from(json['values'] as List),
        );
      case 'regex':
        return RegexParamRule(pattern: json['pattern'] as String);
      default:
        throw TemplateValidationError(
          slot: '<schema>',
          message: 'unknown rule type: ${type ?? "<missing>"}',
        );
    }
  }
}

class IntParamRule extends ParamRule {
  const IntParamRule({this.min, this.max, this.defaultValue});

  final int? min;
  final int? max;
  final int? defaultValue;

  @override
  Object? validate(String slot, Object? value) {
    if (value is bool || value is! int) {
      throw TemplateValidationError(
        slot: slot,
        message: 'expected int, got ${value.runtimeType}',
      );
    }
    if (min != null && value < min!) {
      throw TemplateValidationError(
        slot: slot,
        message: 'value $value < min $min',
      );
    }
    if (max != null && value > max!) {
      throw TemplateValidationError(
        slot: slot,
        message: 'value $value > max $max',
      );
    }
    return value;
  }

  @override
  Map<String, Object?> toMiniAppJson() => <String, Object?>{
    'type': 'int',
    if (min != null) 'min': min,
    if (max != null) 'max': max,
    if (defaultValue != null) 'default': defaultValue,
  };
}

class EnumParamRule extends ParamRule {
  const EnumParamRule({required this.values, this.defaultValue});

  final List<Object?> values;

  /// Default for omitted slot. The schema validator surfaces it via
  /// the same `default` key in [toMiniAppJson] that [IntParamRule] /
  /// [RegexParamRule] use, so missing slots fall through to this
  /// instead of erroring with "required param missing". Omit to
  /// keep the slot strictly required.
  final Object? defaultValue;

  @override
  Object? validate(String slot, Object? value) {
    if (!values.contains(value)) {
      throw TemplateValidationError(
        slot: slot,
        message: 'value $value not in $values',
      );
    }
    return value;
  }

  @override
  Map<String, Object?> toMiniAppJson() => <String, Object?>{
    'type': 'enum',
    'values': List<Object?>.from(values),
    if (defaultValue != null) 'default': defaultValue,
  };
}

/// Numeric param accepting either int or double from the JS bridge
/// (where every number is a JavaScript Number / IEEE 754 double).
/// Used for coordinates / floats that would otherwise reject when an
/// SDK call passes through `JSON.stringify(123)` and the host
/// MethodChannel decoder hands us a `double`.
///
/// `defaultValue` is double-typed for symmetry with the wire shape;
/// passing an int literal still works because Dart auto-promotes.
class NumberParamRule extends ParamRule {
  const NumberParamRule({this.min, this.max, this.defaultValue});

  final double? min;
  final double? max;
  final double? defaultValue;

  @override
  Object? validate(String slot, Object? value) {
    if (value is bool || value is! num) {
      throw TemplateValidationError(
        slot: slot,
        message: 'expected num, got ${value.runtimeType}',
      );
    }
    final v = value.toDouble();
    if (min != null && v < min!) {
      throw TemplateValidationError(slot: slot, message: 'value $v < min $min');
    }
    if (max != null && v > max!) {
      throw TemplateValidationError(slot: slot, message: 'value $v > max $max');
    }
    // Preserve the original numeric runtime type so handlers that want
    // an int (e.g. durationMs) don't unexpectedly receive a double.
    return value;
  }

  @override
  Map<String, Object?> toMiniAppJson() => <String, Object?>{
    'type': 'number',
    if (min != null) 'min': min,
    if (max != null) 'max': max,
    if (defaultValue != null) 'default': defaultValue,
  };
}

class RegexParamRule extends ParamRule {
  RegexParamRule({required this.pattern, this.defaultValue})
    : _re = RegExp(pattern);

  /// Optional default for missing slots. Matches the IntParamRule
  /// shape so the executor's `_maybeDefault` can fill it in without
  /// a type-specific branch. Use sparingly — most RegexParamRule
  /// uses are required (URL paths, package names, ids).
  final String? defaultValue;

  final String pattern;
  final RegExp _re;

  @override
  Object? validate(String slot, Object? value) {
    if (value is! String) {
      throw TemplateValidationError(
        slot: slot,
        message: 'expected str, got ${value.runtimeType}',
      );
    }
    if (_re.matchAsPrefix(value) == null) {
      throw TemplateValidationError(
        slot: slot,
        message: "value '$value' doesn't match pattern '$pattern'",
      );
    }
    return value;
  }

  @override
  Map<String, Object?> toMiniAppJson() => <String, Object?>{
    'type': 'regex',
    'pattern': pattern,
    if (defaultValue != null) 'default': defaultValue,
  };
}

class TemplateValidationError implements Exception {
  const TemplateValidationError({required this.slot, required this.message});

  final String slot;
  final String message;

  @override
  String toString() => 'TemplateValidationError(slot=$slot): $message';
}

class TemplateRenderError implements Exception {
  const TemplateRenderError(this.message);

  final String message;

  @override
  String toString() => 'TemplateRenderError: $message';
}

/// In-memory template definition. Built from the catalog the device
/// fetches at boot.
class CommandTemplate {
  CommandTemplate({
    required this.id,
    required this.permissionId,
    required this.tier,
    required this.requiresStepUp,
    required this.category,
    required this.shellTemplate,
    required Map<String, ParamRule> paramSchema,
    this.description,
  }) : paramSchema = Map.unmodifiable(paramSchema);

  final String id;
  final String permissionId;
  final AdminOpTier tier;
  final bool requiresStepUp;
  final String category;
  final String shellTemplate;
  final Map<String, ParamRule> paramSchema;
  final String? description;

  factory CommandTemplate.fromJson(Map<String, Object?> json) {
    final tierInt = json['tier'] as int;
    final schemaJson = (json['paramSchema'] as Map?) ?? const {};
    final schema = <String, ParamRule>{};
    for (final entry in schemaJson.entries) {
      schema[entry.key as String] = ParamRule.fromJson(
        Map<String, Object?>.from(entry.value as Map),
      );
    }
    return CommandTemplate(
      id: json['id'] as String,
      permissionId: json['permissionId'] as String,
      tier: tierInt == 2 ? AdminOpTier.tier2 : AdminOpTier.tier1,
      requiresStepUp: json['requiresStepUp'] as bool? ?? false,
      category: json['category'] as String,
      shellTemplate: json['shellTemplate'] as String,
      paramSchema: schema,
      description: json['description'] as String?,
    );
  }

  /// Wire shape served to the mini-app via the bridge — matches the
  /// SDK's `CommandTemplate` Zod schema in
  /// ``packages/admin-sdk/src/types.ts``.
  ///
  /// Critical: ``shellTemplate`` is NOT included. The rendered shell
  /// never crosses the bridge — the dispatcher renders it host-side
  /// and runs it via the executor; the mini-app sees only ``id``,
  /// ``tier``, ``paramSchema``, etc. Leaking the shell would tell a
  /// compromised mini-app exactly which native call to abuse if it
  /// ever escaped the sandbox.
  Map<String, Object?> toMiniAppJson() {
    return <String, Object?>{
      'id': id,
      'permissionId': permissionId,
      'tier': tier == AdminOpTier.tier2 ? 2 : 1,
      'requiresStepUp': requiresStepUp,
      'category': category,
      if (description != null) 'description': description,
      'paramSchema': <String, Object?>{
        for (final entry in paramSchema.entries)
          entry.key: entry.value.toMiniAppJson(),
      },
    };
  }
}

/// Catalog of templates known to this device. Built once at boot
/// from the server's response and consulted on every privileged op
/// dispatch.
class TemplateRegistry {
  TemplateRegistry._(this._byId);

  final Map<String, CommandTemplate> _byId;

  /// Build from a list of templates the server published.
  factory TemplateRegistry.fromList(List<CommandTemplate> templates) {
    final m = <String, CommandTemplate>{};
    for (final t in templates) {
      m[t.id] = t;
    }
    return TemplateRegistry._(m);
  }

  CommandTemplate? lookup(String id) => _byId[id];
  Iterable<CommandTemplate> all() => _byId.values;
  bool get isEmpty => _byId.isEmpty;
  int get size => _byId.length;
}

/// Validate [params] against [template]. Returns a new map with
/// defaults filled in. Throws [TemplateValidationError] on first
/// failure — same strict semantics as the backend (unknown slots
/// rejected, missing required slots rejected).
Map<String, Object?> validateParams(
  CommandTemplate template,
  Map<String, Object?>? params,
) {
  final input = Map<String, Object?>.from(params ?? const {});

  // Reject unknowns first — keeps a future schema change from
  // accidentally honouring a stale param.
  final extras = input.keys.toSet().difference(
    template.paramSchema.keys.toSet(),
  );
  if (extras.isNotEmpty) {
    throw TemplateValidationError(
      slot: extras.first,
      message: 'unknown slots: $extras',
    );
  }

  final out = <String, Object?>{};
  for (final entry in template.paramSchema.entries) {
    final slot = entry.key;
    final rule = entry.value;
    if (!input.containsKey(slot)) {
      // Default, if any.
      if (rule is IntParamRule && rule.defaultValue != null) {
        out[slot] = rule.defaultValue;
        continue;
      }
      throw TemplateValidationError(
        slot: slot,
        message: 'required param missing',
      );
    }
    out[slot] = rule.validate(slot, input[slot]);
  }
  return out;
}

final _placeholderRe = RegExp(r'\{([a-z][a-z0-9_]*)\}');

/// Render the template's shell string with validated params
/// substituted. Mirrors the Python implementation byte-for-byte.
String renderCommand(
  CommandTemplate template,
  Map<String, Object?> validatedParams,
) {
  final rendered = template.shellTemplate.replaceAllMapped(_placeholderRe, (
    match,
  ) {
    final slot = match.group(1)!;
    if (!validatedParams.containsKey(slot)) {
      throw TemplateRenderError(
        "template '${template.id}' references unknown slot '$slot'",
      );
    }
    return validatedParams[slot].toString();
  });

  if (_placeholderRe.hasMatch(rendered)) {
    throw TemplateRenderError(
      "template '${template.id}': unsubstituted placeholder after render",
    );
  }
  return rendered;
}

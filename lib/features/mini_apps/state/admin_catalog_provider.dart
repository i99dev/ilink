import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Legacy signed command templates require the retired issuer. Family APIs
/// continue to use their bundled schema and local consent.
final adminCatalogProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) async => const [],
);

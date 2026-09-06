import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/dio_factory.dart';
import 'catalogue_http.dart';

/// Public catalogue transport with the shared download consent policy.
final catalogueHttpProvider = Provider<CatalogueHttp>(
  (ref) => CatalogueHttp(dio: ref.watch(dioProvider(DioPurpose.cdn))),
);

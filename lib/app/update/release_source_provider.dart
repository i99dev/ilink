import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../kernel/api/dio_factory.dart';
import '../../kernel/update/data/github_release_source.dart';
import '../../kernel/update/data/release_source.dart';

final releaseSourceProvider = Provider<ReleaseSource>((ref) {
  return GitHubReleaseSource(dio: ref.watch(dioProvider(DioPurpose.cdn)));
});

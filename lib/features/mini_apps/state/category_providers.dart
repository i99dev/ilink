import 'package:flutter_riverpod/flutter_riverpod.dart';

final categoriesProvider = FutureProvider<List<String>>(
  (ref) async => _fallbackSlugs,
);
const List<String> _fallbackSlugs = [
  'navigation',
  'media',
  'vehicle',
  'productivity',
  'communication',
  'entertainment',
  'services',
  'lifestyle',
  'developer',
  'other',
];

/// Currently-selected category slug, or ``null`` for "All".
class SelectedCategoryController extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? slug) => state = slug;
}

final selectedCategoryProvider =
    NotifierProvider<SelectedCategoryController, String?>(
      SelectedCategoryController.new,
    );

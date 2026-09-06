/// Local namespaces retained to migrate saved palette specifications.
enum ThemeCatalogEndpoint {
  public(cacheKey: 'themes.catalog'),
  me(cacheKey: 'themes.catalog.me');

  const ThemeCatalogEndpoint({required this.cacheKey});
  final String cacheKey;
}

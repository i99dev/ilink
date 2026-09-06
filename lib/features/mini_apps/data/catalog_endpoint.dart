/// Legacy local storage namespaces retained for installed-bundle migration.
enum CatalogEndpoint {
  public(cacheKey: 'mini_apps.catalog'),
  me(cacheKey: 'mini_apps.catalog.me');

  const CatalogEndpoint({required this.cacheKey});
  final String cacheKey;
}

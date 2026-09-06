# Car SDK

Brand-agnostic SDK for OEM-framework car features. Same API across
BYD / Geely / NIO / Tesla / etc — drop a folder under `brands/` to
add a new OEM.

## Layout

```
lib/sdk/
  car.dart                          public barrel — import this
  car/
    brand.dart                      CarBrand enum + autodetection
    catalog.dart                    CarCatalog interface
    client.dart                     CarClient interface (read/watch/invoke)
    feature.dart                    CarFeature record
    providers.dart                  reactive Riverpod providers
  brands/
    byd/
      byd_catalog.dart              implements CarCatalog from
                                    assets/byd/catalog.tsv
      byd_client.dart               implements CarClient via the
                                    BYD MethodChannel/EventChannel
    geely/                          (future)
    nio/                            (future)
    tesla/                          (future)
```

The BYD catalog is bundled directly in [assets/byd](../../assets/byd):
`catalog.tsv` supplies feature names and IDs; `catalog_meta.yaml` supplies
metadata. No secrets repository, catalog download or server provisioning is
required. [Release asset validation](../../scripts/ci/prepare-offline-release.sh)
checks the public offline assets without regenerating the release identity.

## Consumer usage

```dart
import 'package:ilink/sdk/car.dart';

class BatteryWidget extends ConsumerWidget {
  Widget build(ctx, ref) {
    // Reactive — auto-rebuild on push.
    final live = ref.watch(featureLiveProvider(
      'Statistic.STATISTIC_SOC_BATTERY_PERCENTAGE',
    ));
    return live.when(
      loading: () => const CircularProgressIndicator(),
      error:   (_, __) => const Icon(Icons.error_outline),
      data:    (f) => f.isLive
          ? Text('${f.value}${f.meta?.unit ?? ""}')
          : Text(f.meta?.description ?? '—'),
    );
  }
}
```

## Discovery / search

```dart
final catalog = await ref.read(carCatalogProvider.future);

// All features in a category
final doors = catalog.byCategory('doors');

// Search by description
final tireFeatures = catalog.searchByDescription('tyre pressure');

// All categories the current brand exposes
final cats = catalog.categories();  // ["doors", "climate", "battery", …]
```

## Write API

```dart
final api = ref.read(carClientProvider);
await api.invoke('door.lock');                          // brand action_id
await api.invoke('ac.power', {'on': true});             // typed args
await api.invoke('ac.fan', {'value': 3});
```

Action IDs are brand-specific — defined in
`.secrets/<brand>/actions.yaml` (or, for BYD today, in the existing
`fast_actions` block in the encrypted car_table).

## Adding a new brand

1. Get the new brand's framework reflection dump → save as
   `.secrets/<brand>/catalog.tsv`.
2. Add entries to `.secrets/<brand>/catalog_meta.yaml` for the
   well-known features your widgets care about.
3. Add a brand entry to `lib/sdk/car/brand.dart` enum.
4. Implement `lib/sdk/brands/<brand>/<brand>_catalog.dart` (mirror
   `byd_catalog.dart` shape).
5. Implement `lib/sdk/brands/<brand>/<brand>_client.dart` (mirror
   `byd_client.dart`; wraps the brand's MethodChannel).
6. Wire the brand in `lib/sdk/car/client.dart` →
   `carClientProvider` switch.
7. Wire the brand in `lib/sdk/car/providers.dart` →
   `carCatalogProvider` switch.
8. Add brand-side Kotlin handlers under
   `android/.../sdk/brands/<brand>/`.
9. Add asset declarations to `pubspec.yaml`.

That's it — every existing widget that consumes `featureValueProvider`
or `carCatalogProvider` automatically works on the new brand.

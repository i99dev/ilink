/// Legacy re-export shim.
///
/// The brand-neutral label -> framework-name map and the boot warm
/// set used to live here; they now live in the single source of
/// truth at [byd_catalog.dart] (which also carries the per-signal
/// metadata required by [BydPublicCatalog]).
///
/// This file is kept so existing imports compile unchanged. New
/// code should import `byd_catalog.dart` directly.
library;

export 'byd_catalog.dart' show bydStatusLabelToCatalog, bydBootWarmSet;

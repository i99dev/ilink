# Runtime vehicle profile

CarProfileRegistry resolves supported native definitions, named stub trims and DiLink-generation fallbacks. Probe-validated definitions live under android/app/src/main/kotlin/com/i99dev/ilink/car/profiles/definitions. Unknown trims remain conservative; a friendly name is not proof that an operation works.

The platform bridge exposes the active profile to carProfileProvider. Consumers use its identity, capabilities and sparse action-support map. CarCommandRouter rejects an explicitly unsupported action when the profile is confident, while the local native dispatcher remains authoritative for actual execution.

There is no hosted vehicle-capabilities overlay to deploy or synchronize. Legacy wire field names and existing cached values may remain for compatibility, but fresh resolution uses local native definitions. Update verified profile data in the source and distribute it with an app release.

See [detection](detection.md), [static profiles](static-profile.md) and [adding a trim](adding-a-trim.md).

# Optional internet features

There is no hosted-service reconnection mode. The former account, payment, MQTT, remote-help, cloud-voice and cloud-sync implementations were removed from the app.

All choices in Settings > Optional Services default off, including upgraded installs whose old preferences contain retired service names. Enabling a choice permits only its direct internet category; no ilink account is required.

| Setting | What it permits | Available when off |
| --- | --- | --- |
| Downloads | Supported voice-model downloads from the publisher, remote images/resources and declared mini-app network origins | Bundled English speech, compatible imported/installed models, installed mini-apps/themes and local file imports |
| Streaming | User-selected HTTP radio/TV playback | Saved catalog entries, favorites, local playlist files and supported direct local media; an imported playlist can still contain internet URLs |
| GitHub updates | GitHub release lookup and APK download | Current installed app and all local functionality; installation still requires Android confirmation |

Disabling a category cancels registered work. Streaming revocation also stops native network playback across the relevant player processes. Downloads revocation recreates open mini-app documents with offline restrictions, which may discard unsaved page state. See [media boundaries](media-webview-egress.md) for details.

These network choices do not grant mini-app vehicle or native permissions. Those scopes require separate local consent bound to the app ID and archive SHA-256, are enforced at runtime, and can be reviewed or revoked through **Local permissions**. Unknown and administrator scopes are denied.

## Retired services

| Removed hosted capability | Local replacement or explicit limit |
| --- | --- |
| Login, pairing, OTP, account profile and ownership transfer | Device-local settings/profile; remote ownership/account records are not recreated locally |
| Billing, subscriptions, checkout, trials and voice-credit wallets | Removed entirely; local features have no payment requirement |
| Backend command-table provisioning | Bundled command tables plus valid existing local caches, with the original safety dispatcher |
| Cloud workflow synchronization/template publishing | Local create/import/edit/enable/run and persistent workflow execution |
| Cloud voice broker, provider token minting and telemetry | On-device speech and local command routing; remote AI conversation is not simulated |
| Backend catalogs | Bundled radio data, local imports and compatible existing mini-app/theme/TV data |
| MQTT remote commands/location/status and remote-help relay | Removed; local dashboard controls remain available |
| Remote certificates/session capabilities for privileged mini-app extensions | New issuer-bound installs need review; cached tier-1 templates may still work, while tier-2 retains issuer/capability checks and fails closed without valid authority |

The default APK includes English speech. Other primary Vosk models use publisher URLs after opt-in. The former custom Arabic Moonshine fallback can load an existing local model but has no new hosted download path.

Infrastructure deletion and final release status are recorded separately in [the cleanup record](standalone-cleanup.md). Removing a client is not evidence that a remote resource was deleted. Historical service audits were archived outside Git.

# Mini-app bridge reference

The primary viewer exposes a fixed handler set. Use the checked-in packages/sdk client and types for the current wire contract; the runtime implementation is lib/features/mini_apps/presentation/mini_app_viewer.dart and lib/features/mini_apps/bridge.

getContext returns local context, including app identity, language/theme and scope-filtered vehicle identity. The local user namespace is not a hosted account. car.list, car.read, car.subscribe, car.command and related identity/connection calls require their supported local scopes. location.read and browser geolocation require location.read. Workflow handlers require workflow.read or workflow.write as appropriate. Family calls are validated by FamilyExecutor.

Grants must match the installed app ID and exact archive SHA-256. Missing or revoked permissions return a denial; streaming subscriptions also recheck authority. See [security](security.md).

The former callApi proxy and its fuel/weather/account endpoints do not exist. No access token is supplied to JavaScript. Optional declared network resources are subject to the owner's internet consent and WebView boundary; use local application APIs for core functions.

_admin.exec remains a separate legacy signed-template compatibility path. It does not mint authority or permit new issuer-bound installations. See [legacy administrator extensions](admin-permissions.md).

Secondary native WebViews are local visual surfaces with no host JavaScript bridge. A mini-app must request any supported surface operation through its primary scoped session.

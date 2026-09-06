# Shared infrastructure

lib/kernel contains local settings, localization, themes, logging, shared identity/permission types and consent for optional internet operations. It may depend on sdk, platform and other kernel modules, but not app or features.

Downloads, Streaming and Updates are the only optional internet services. They default off. No account, payment or MQTT service is present. Device-local IPC and vehicle signal subscriptions continue independently.

See [configuration](../workflow/configuration.md), [security](security/README.md), and [optional services](../offline-first/service-reconnection.md).

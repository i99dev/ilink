# Home-screen shortcuts

A pinned mini-app shortcut opens the host and resolves the installed app through the normal launch path. Android owns the pin confirmation. The mini-app remains inside the same viewer and retains manifest validation, local scope consent and browser restrictions.

A shortcut is not a separate web installation and grants no additional permissions. The host context uses a local device namespace, and there is no callApi account/backend proxy. Removing or replacing an installed bundle affects future launches and digest-bound consent normally.

See [bridge](bridge-api.md) and [security](security.md).

# 7. Open issues & next diagnostics

> **UPDATE 2026-05-18 — largely RESOLVED.** Passenger/FSE works
> on-car (DiShare protocol fixed + synthetic FSE card shipped). The
> cluster shell-`am start` command is proven to render on displays
> 3/4 from a shell-uid stream. The only residual is operational:
> ensuring car-ilink's embedded self-ADB bridge is connected/
> authorized at drop time for the cluster path. The historical
> investigation log below is kept for context. See
> `08-di51-vs-di50-audit.md` for the current working architecture.
>
> **UPDATE 2026-05-20 — cluster touchpad input routing RESOLVED.**
> Once an app is on the Driver Dashboard (4), the cluster touchpad
> now drives it: cursor renders on display 4 (identity remap — 3 and
> 4 are siblings, not a parent/child mirror, so cursor-on-3 was
> invisible), and taps inject on display 2 (`inputRemap {4→2}` —
> display 4 has no touchable window; the cast app's focusable window
> lives on the DiShare source). Verified on-car: `input -d 2 tap`
> reaches the cast, `input -d 4 tap` drops. Also: `GENERIC_DI50` now
> inherits the full Di5.0 topology so unprofiled Di5.0 cars get the
> same routing. See [01](./01-display-topology.md#cluster-touchpad-routing-cursor-vs-tap-land-on-different-displays)
> + [05](./05-launch-mechanisms.md#cluster-touchpad--interaction-transport-after-the-app-is-placed).

State after a long RE+on-car session. The **protocol is solved**; the
**remaining gap is operational** and needs hands-on, on-device
debugging — not another remote build cycle.

## The (now mostly-closed) open issue

> **Foreign apps never land on displays 2/3/4 in car-ilink; they
> stay on display 0** — even though the command + uid match Shaheen,
> and DiShare accepts our client.

Driver Dashboard *appeared* to work once, then later "drag/drop
between Driver and Small Panel still shows on the same screen
(Driver/display 0)". Across the whole session, `dispatchShellLaunch` /
`fastCast` appeared in logs only ~twice — most drops produced **no
launch-path log at all**.

### Two live hypotheses (not yet disambiguated)

1. **Self-ADB bridge not connected/authorized at drop time.**
   `AdbShellBridge.shell()` needs the loopback adbd authorized for the
   *app's own* adb key (the `com.android.systemui/.usb
   .UsbDebuggingActivity` "Allow USB debugging?" prompt was seen
   repeatedly this session). If `ensureAdb()` fails, `shell()` returns
   `"Error: adb connect failed: …"` and `dispatchShellLaunch`
   no-ops — while the picker card still shows optimistic feedback.
   Shaheen avoids this with a far more robust `AdbConnectionManager`
   (persistent `AdbKeyStore`, QR pairing, `connectionLoop`
   auto-reconnect, `StateFlow` gating); ours is best-effort.
   *Note:* a late capture did show `I AdbShellBridge: adb connected`,
   so the bridge connects at least sometimes — connectivity may be
   intermittent rather than absent.
2. **The Dart slide-panel drop isn't reliably reaching
   `pkg.launch`→`handleLaunch`→`ShellLaunch`.** "Card reacts but
   nothing casts" + near-total absence of launch-path logs is also
   consistent with the drop not invoking the bridge at all.

## Next diagnostics (owner, on the physical car, interactive)

Do these with the car in front of you and a *reliable* adb session —
the remote tunnel's logcat kept rotating/dying, which is why this
couldn't be closed remotely.

1. **Sanity-check the cluster assumption directly.** From a host
   shell: `adb shell am start -S --display 4 --activity-multiple-task
   --activity-clear-top -n com.android.chrome/com.google.android.apps
   .chrome.Main`. Does Chrome appear on the Driver display?
   - **Yes** → cluster *is* reachable from shell uid; the gap is
     purely our self-ADB-bridge connectivity → harden
     `AdbShellBridge`/pairing toward Shaheen's `AdbConnectionManager`
     persistence model.
   - **No** → the am-start theory for cluster is wrong on this car;
     re-RE Shaheen's `AdbConnectionManager.executeRaw`/`submit` for an
     extra step (or confirm Shaheen's cluster is itself a mirror).
2. **Confirm the bridge state at the moment of a drop.** Tail
   `logcat -s AdbShellBridge:* DishareTransport:* PackagePlatformPlugin:*`
   (enlarge buffer: `logcat -G 16M`) and drop one app on Driver. Look
   for: `AdbShellBridge: adb connected` vs `Error: adb connect
   failed`; `cluster am-start attempt N`; `not on display 4`.
3. **Confirm the drop fires the bridge at all.** If step 2 shows *no*
   `dispatchShellLaunch`/`cluster am-start` line on a drop, the bug is
   the Dart UI → bridge path, not DiShare/ADB — investigate
   `display_drop_picker` `onAccept` → `pkgBridge.launch` → planner on
   L5.
4. **FSE check.** Drop a *real, visible* app (Chrome — NOT
   `app.revanced.android.gms`/microG which has no UI) on FSE Co-pilot;
   confirm `fastCast step5 quickShare ok` *and* the passenger panel
   paints. If binder ok but blank, revisit the foreground+delay timing
   (Shaheen uses 1200 ms).

## Recommendation

The faithful Shaheen ports are implemented and the binder protocol is
proven correct. Recommended path:

1. **Commit** the proven, correct work (DiShare callback-binder +
   reply fix, `ShellLaunch` routing + verify-retry, FSE
   foreground+delay, planner-test update, picker linger fix).
2. Treat **self-ADB-bridge robustness** as the next workstream —
   port Shaheen's `AdbConnectionManager` persistence/auto-reconnect
   model so the shell-uid stream is reliably up when a drop happens.
   That is the most likely thing standing between "protocol correct"
   and "app visibly on the cluster".

## Cross-references

- Working spec: [04 — Shaheen reference](./04-shaheen-reference-architecture.md)
- Protocol detail: [03 — DiShare binder protocol](./03-dishare-binder-protocol.md)
- Why placement is hard: [01 — Display topology](./01-display-topology.md) (`FLAG_OWN_CONTENT_ONLY`)
- Memory: `project_l5_dishare_and_launch_decoder` (the running RE log)

# DiLink 5.0 — Displays & Multi-Screen Control (reference)

Everything car-ilink needs to know to move a foreign app onto a
secondary screen on a **DiLink 5.0** head unit (Leopard 5 / Song
PLUS / Di5.0 BYD-container trims).

Status: **reverse-engineered + partially on-car verified, 2026-05-18.**
Primary on-car subject: live **Leopard 5** behind tunnel
`127.0.0.1:5999`, ROM `23.1.4.2510219.1`, `com.byd.dishare`
**`1.5.1.1.e027a7e`**. Ground-truth reference: the user's working
third-party app **`Shaheen.apk`** (`com.the4.navigator`,
un-obfuscated `DiShareCore` + `RouteEngine` + `AdbConnectionManager`).

> This supersedes the DiShare sections of `../DISPLAY_WEBVIEW_AUDIT.md`
> for Di5.0. The L5 RE there was derived from a *different* reference
> launcher and is wrong in places — see [03](./03-dishare-binder-protocol.md).

## Read in this order

| # | Doc | What it answers |
|---|-----|-----------------|
| 1 | [Display topology](./01-display-topology.md) | What screens exist, their IDs, why `am start --display N` is hard |
| 2 | [Car detection](./02-car-detection.md) | How the runtime knows it's a Di5.0 / L5 |
| 3 | [DiShare binder protocol](./03-dishare-binder-protocol.md) | The real `IDiShareApiService` contract on this ROM |
| 4 | [Shaheen reference architecture](./04-shaheen-reference-architecture.md) | How the *working* app does it (the spec to match) |
| 5 | [Launch mechanisms](./05-launch-mechanisms.md) | IVI / FSE / cluster — which transport, why |
| 6 | [car-ilink implementation](./06-car-ilink-implementation.md) | What we built, where it lives, current state |
| 7 | [Open issues & diagnostics](./07-open-issues-and-diagnostics.md) | What's still broken + the exact next steps |
| 8 | [Di5.1 vs Di5.0 audit + diagram](./08-di51-vs-di50-audit.md) | The one end-to-end decision diagram & transport matrix |

## TL;DR

- **Three screen classes on Di5.0:** the IVI (display 0, real internal
  panel), the **FSE / passenger** (display 2), and the **cluster**
  (displays 3 = "Small Panel", 4 = "Driver Dashboard"). 2/3/4 are
  `VIRTUAL`, `FLAG_PRESENTATION`, **`FLAG_OWN_CONTENT_ONLY`**, owned by
  `com.byd.containerservice` (uid 1000).
- **There is no single transport.** The working app uses **two**:
  - **FSE / passenger** → DiShare *mirror* (`IDiShareApiService`
    binder: `register` → `setVideoSize` → `setGestureShare` →
    `quickShare("fse")`), **after foregrounding the app on the IVI**.
  - **Cluster (3/4)** → **`am start -S --display N
    --activity-multiple-task --activity-clear-top -n <component>`**
    over a real ADB **`shell:`** stream (shell uid). DiShare quickShare
    does **not** paint the cluster on this ROM.
- **Opcodes (this ROM, ground truth from Shaheen):** `register=1`,
  `quickShare=8`, `setGestureShare=9`, `setVideoSize=11`,
  `unregister=7`, `finishShare=10`. Interface descriptor
  `com.byd.dishare.api.IDiShareApiService`; client callback
  `com.byd.dishare.api.IDiShareApiClient`.
- **The bug that blocked car-ilink for a long time:** our client
  callback binder answered `true` to *every* transaction and never
  returned the interface descriptor on `INTERFACE_TRANSACTION`, so
  DiShare silently refused to commit the mirror even though
  `register`/`quickShare` "succeeded". Fixed (see [03](./03-dishare-binder-protocol.md)).
- **The remaining gap is operational, not protocol:** apps never land
  on displays 2/3/4 in car-ilink tests (always display 0). The
  command + uid match Shaheen; the suspect is our embedded self-ADB
  bridge connectivity at drop time. See [07](./07-open-issues-and-diagnostics.md).

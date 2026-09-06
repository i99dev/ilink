# Per-op compatibility matrix

What works on which trim today, with the rationale for every gate.
Updated whenever a new model is profiled — the textproto's
`model_match` field is the runtime mechanism, this doc is the
human-readable view.

## Matrix

| Op | L8 (Di5.1, Huawei) | L5L (Di5.1, BYD) | 5f (Di5.0) | Reason for divergence |
|---|---|---|---|---|
| `pkg.launch_on_display` | ✅ | ✅ | ❌ | `ro.byd.ui.splitscreen=0` on Di5.0 → no `am start --display N` support |
| `pkg.stack_list` | ✅ | ✅ | ❌ | `am stack list` on Di5.0 returns the legacy single-stack shape; the parser breaks |
| `pkg.stack_move_task` | ✅ | ✅ | ❌ | Same multi-display dependency; `move-task` no-ops on Di5.0 |
| `pkg.cluster_placeholder_component` | ✅ | ✅ | ❌ | Used by `pkg.move`; no point if `move-task` doesn't work |
| `surface.am_start_cluster` | ✅ | ✅ | ❌ | Multi-display + ClusterActivity on the secondary display |
| `surface.amap_force_stop` | ✅ Huawei | ✅ BYD | n/a | Per-model package: `com.example.amapservice` vs `com.byd.naviauto`. 5f doesn't need eviction (no cluster slot to fight for) |
| `gesture.input_tap` | ✅ | ✅ | ⚠️ likely | `input -d N tap` should work on Di5.0 since it predates the multi-display work — verify on hardware |
| `gesture.input_swipe` | ✅ | ✅ | ⚠️ likely | Same as input_tap |
| `display.cluster_name_marker` | ✅ | ✅ | ✅ | Pure DisplayManager Java API; reads `Display.name` regardless of generation |
| `display.amap_slot_marker` | ✅ | ✅ | ✅ | Same |
| All `bridge.*` calls (call_api, get_context, log_*) | ✅ | ✅ | ✅ | Pure Java APIs in our process, model-agnostic |

`✅` = confirmed/expected to work; `❌` = doesn't apply, dispatcher
returns null and mini-apps see "unsupported on this model"; `⚠️`
= not yet verified on hardware, expected based on Android API
availability.

## Why model_match works the way it does

The textproto in `android/app/src/main/assets/offline/mini_app_table.textproto`
declares per-model variants with the same `op_token` but different
`model_match` sets:

```
ops {
  family_id: "surface"
  op_id: "amap_force_stop"
  op_token: "1774bb3e78e104a4"
  arg_template: "am force-stop com.example.amapservice"
  model_match: "l8"
}
ops {
  family_id: "surface"
  op_id: "amap_force_stop"
  op_token: "1774bb3e78e104a4"
  arg_template: "am force-stop com.byd.naviauto"
  model_match: "l5l"
}
ops {
  family_id: "surface"
  op_id: "amap_force_stop"
  op_token: "1774bb3e78e104a4"
  arg_template: "am force-stop com.byd.naviauto"
  model_match: "di5.1"
}
```

Selection rule (`MiniAppDispatcher.selectByModel`):

1. Filter to routes where `model_match` is empty OR contains the
   active modelId.
2. Among the remaining, pick the route with the LARGEST non-empty
   `model_match` set ("most specific intent wins").
3. Empty `model_match` ranks lowest — it's the catch-all fallback.
4. No match at all → null → caller surfaces "unsupported on this
   model" via the existing structured-error path.

So for an L8 head unit (modelId=`l8`):
- Route 1 (`model_match: l8`) matches; specificity = 1
- Route 2 (`l5l`) doesn't match; skip
- Route 3 (`di5.1`) matches (because L8 is in the di5.1 family);
  specificity = 1
- **Tie broken by declaration order** → first match wins → L8
  variant gets the Huawei package. (Note: when tie-break matters,
  declare the per-trim variant BEFORE the per-family fallback.)

For L5L (modelId=`l5l`):
- Route 2 matches; specificity = 1
- Route 3 matches; specificity = 1
- Same tie → declaration order → L5L variant wins (it comes
  before the di5.1 fallback in the textproto).

For 5f (modelId=`5f`, dilinkFamily=`di5.0`):
- None match → return null → "unsupported on this model"

## Adding a new op-per-model variant

1. In `android/app/src/main/assets/offline/mini_app_table.textproto`, copy the
   existing op block and edit:
   - Keep the same `op_token`
   - Edit `arg_template` to match the new trim's binding
   - Set `model_match` to the new variant id (single string) or
     family id (`di5.0` / `di5.1`)
2. Place per-trim entries BEFORE per-family fallbacks so
   declaration-order tiebreaks work in your favour.
3. Re-run `dart run tool/generate_op_tokens.dart` if a new op is
   being added (no need if just adding a model variant of an
   existing op — same token).
4. Rebuild the APK to include the edited public mini_app_table.textproto.
5. Run native resource and routing tests; retain verified per-model safety constraints.

## Smoke test

After landing a per-model PR, run on the target hardware:

| Test | L8 | L5L | 5f |
|---|---|---|---|
| App boots, settings hydrate, no SIGSEGV | ✅ | ✅ | ✅ |
| Local detected model matches expected modelId | ✅ | ✅ | ✅ |
| Mini-apps store loads catalog | ✅ | ✅ | ✅ |
| Install + launch pkg-launcher mini-app | ✅ | ✅ | ✅ (single-display) |
| `pkg.launch_on_display` to cluster | ✅ | ✅ | structured error: "unsupported on di5.0" |
| `pkg.move` IVI → cluster | ✅ | ✅ | structured error |
| `surface.create` on cluster | ✅ | ✅ | structured error |
| `gesture.input_tap` on cluster (a11y disabled) | ✅ | ✅ | ⚠️ verify |
| Reboot → BootCompletedReceiver replays pinned mini-apps | ✅ | ✅ | n/a (no cluster) |

Each line that fails on a model where it should succeed is either
a textproto entry that needs updating or a `_classify` rule that
needs adding to the model detector.

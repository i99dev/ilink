# 3. DiShare binder protocol (this ROM: `com.byd.dishare 1.5.1.1.e027a7e`)

The `IDiShareApiService` contract, **ground-truthed from the user's
working `Shaheen.apk`** (`com.the4.navigator.DiShareCore`,
un-obfuscated). This corrects the in-repo RE that came from a
different reference launcher.

## Service / interface identity

| | value |
|---|---|
| package | `com.byd.dishare` (`/system/app/DiShare/DiShare.apk`), vc `10501001`, vn `1.5.1.1.e027a7e` |
| bind action | `com.byd.dishare.api.DiShareApiService` (no manifest permission guard on `onBind`) |
| service interface descriptor | `com.byd.dishare.api.IDiShareApiService` |
| client callback descriptor | `com.byd.dishare.api.IDiShareApiClient` |

> Decompiling the DiShare APK itself is a dead end: it has **no
> `IDiShareApiService` AIDL stub**; `DiShareApiService.onBind` returns
> an obfuscated binder (`c.d.b.f.y` extends `c.d.b.f.e0`, packed-switch
> keys 1–15). The reliable source of the contract is the working
> *client* (Shaheen), not the obfuscated service.

## Opcodes (authoritative — from Shaheen `DiShareCore`)

| op | method | parcel after `writeInterfaceToken(SVC_DESC)` | returns |
|----|--------|----------------------------------------------|---------|
| 1 | `register(pkg)` | `writeStrongBinder(cb)` + `writeString(pkg)` | (none — see reply note) |
| 8 | `quickShare(deviceTag)` | `writeStrongBinder(cb)` + `writeString(deviceTag)` | — |
| 9 | `setGestureShare(enabled)` | `writeStrongBinder(cb)` + `writeInt(0/1)` | — |
| 11 | `setVideoSize(w,h)` | `writeStrongBinder(cb)` + `writeInt(w)` + `writeInt(h)` | — |
| 7 | `unregister()` | `writeStrongBinder(cb)` | — |
| 10 | `finishShare()` | `writeStrongBinder(cb)` | — |

These are the **original** car-ilink opcodes — `1/8/9/11`. A
mid-investigation attempt to "correct" them to `7/8/5/15` (from
reading the obfuscated service `onTransact`) was **wrong** and was
reverted. Trust Shaheen.

`deviceTag` values Shaheen passes to `quickShare`: **`ivi`, `fse`,
`cluster_c`, `cluster_tr`** (but see [05](./05-launch-mechanisms.md) —
Shaheen routes cluster to am-start, not quickShare).

## Reply handling — there is **no AIDL boolean**

Shaheen's `DiShareCore.txn(code, ParcelWriter)`:

```
data.writeInterfaceToken(SVC_DESC)
data.writeStrongBinder(cb)          // the client callback binder
<method-specific args>
svc.transact(code, data, reply, 0)  // non-oneway
reply.readException()               // throws on a real service-side error
return true                         // ← NEVER reads a reply int
```

Implication: a "successful" call is **`transact` + `readException`
without throwing**. DiShare does **not** write a boolean result.

> **The original false-success bug:** car-ilink's `transact()`
> swallowed `readException()` and returned `true` unconditionally — so
> a real failure looked like success (green check, nothing casts). A
> "fix" that read `reply.readInt()` was *worse* — it read past
> end-of-parcel → `0` → `register` falsely "failed". Correct = match
> Shaheen: `reply.readException()` (propagate → caught → false) then
> `return true`, **no `readInt`**.

## The real blocker — the client callback binder

DiShare validates the client by transacting back on the `cb` binder.
Shaheen's `DiShareCore$1` (the `cb`) `onTransact`:

```kotlin
attachInterface(stub, "com.byd.dishare.api.IDiShareApiClient")

onTransact(code, data, reply, flags):
  if (code == 1) {                       // mirror-state notify
      data.enforceInterface(CB_DESC)
      val state = data.readInt()         // logged; ack
      return true
  }
  if (code == INTERFACE_TRANSACTION) {   // 0x5f4e5446
      reply.writeString(CB_DESC)         // ← DiShare validates this
      return true
  }
  return super.onTransact(code, data, reply, flags)
```

car-ilink's old `clientBinder` returned `true` for **every** code
and **never wrote the descriptor on `INTERFACE_TRANSACTION`**. DiShare
could not verify our client interface, so it **silently refused to
commit the mirror** even though `register`/`quickShare` returned ok.

**Fix shipped** in `DishareTransport.DishareSession.clientBinder`
(`android/app/src/main/kotlin/com/i99dev/ilink/pkg/DishareTransport.kt`):
faithful port of the contract above (`code==1` → drain+readInt+true;
`code==INTERFACE_TRANSACTION` → `reply?.writeString(CLIENT_IFACE)`;
else `super.onTransact`). **Proven on-car** — DiShare's own service
then logged us by name:

```
I DishareTransport: fastCast step2 register ok
D DiShareApiServiceImpl: setGestureShare= true packageName=app.revanced.android.gms
I DishareTransport: fastCast step5 quickShare ok
```

i.e. the binder protocol is now correct end-to-end; DiShare accepts
our client. (Whether the *mirror visibly paints* depends on the app
being foreground first — see [05](./05-launch-mechanisms.md).)

## DiShare device-tag inventory caveat

The DiShare APK's `<clinit>` screen map exposes
`ivi/fse/rse_l/rse_r/tv/overhead` (the `screen_*` registry). Shaheen
passes `cluster_c/cluster_tr` to `quickShare` regardless — but Shaheen
**does not actually cast the cluster via quickShare** (those targets
route to am-start, see [04](./04-shaheen-reference-architecture.md)).
Net: treat `fse` as the only quickShare target proven meaningful on
this ROM; the device-tag list is version-specific — re-verify per
DiShare version.

# Rules

Hard rules. Cheap to follow, expensive to violate. Each is rule + **why** +
**when to apply**.

For the layered defense-in-depth behind §9–§11 (what attack each layer
addresses, rotation SOPs, incident response), see
[offline-first/security-network-review.md](offline-first/security-network-review.md).

## 1. No car-side probing while the user is in the car

Only `*.status` reads are safe. Anything that `set`s a value — door lock,
window, seat position, massage mode, fragrance — can cycle hardware and
startle the driver.

**Why.** Actuators are physical. A stray `door.unlock` in a parking lot is a
real problem.

**When.** Any development session where the actual car is driveable and a
human might be in it. If you're alone in a parked car with the bay doors
closed, use your judgment.

## 2. `lib/features/_car_domain/` is bypass-only

Only ADB / feature-ID / raw-binder bypass code belongs here. Any standard
Android framework integration (e.g. `startActivity`) goes under
`lib/features/<name>/data/`.

**Why.** The bypass surface is security- and hardware-sensitive. Keeping it
narrow means every file under `_car_domain/` is known to touch feature
IDs or daemon operations. Cross-contamination hides real risks.

**When.** Any time you're tempted to drop "anything car-related" under
`_car_domain/`. Ask: does it go through `DashDaemonClient` or the
`byd_airconditioning` raw binder? If no, it's a regular feature
(`lib/features/<feature>/`), not bypass.

## 3. Never leave orphan `app_process64` helpers running

If a probe crashes or you `Ctrl+C` mid-run, the helper on the car can keep
issuing actuator commands.

**Why.** Queued commands fire after you've moved on — seat heat cycling,
AC toggling, fragrance puffing. Confusing at best; a parked-car battery
drain at worst.

**When.** Every time you run a one-shot helper via
`adb shell app_process64`. Before starting a new one:
`adb shell pkill -9 -f app_process64`.

## 4. Heat / vent use AC domain (`dt=1000`), not SETTING (`dt=1023`)

Heat and vent level `setInt` on `dt=1023` returns `INVALID_OP` via the
persistent daemon even though the unit DEX accepts it directly. Route these
through `dt=1000` (AC domain).

**Why.** Verified on Leopard 8. The daemon path drops SETTING-domain writes
for these keys; the AC path accepts them.

**When.** Any new heat/vent wiring. Copy the shape of the existing
`heat.drv.level` / `vent.drv.level` ids in `UnitDispatcher.kt` — don't
invent a new routing.

## 5. Action ids must match `UnitDispatcher` keys exactly

A typo in a Dart action id returns a silent "unknown action" — no exception,
just a dud response.

**Why.** The bridge doesn't validate against the dispatcher's table.
Untracked ids fall through the dispatcher's default branch with a log
line you may not be watching.

**When.** Copy-paste the id from `UnitDispatcher.kt` when adding a new
command. Don't retype.

## 6. Location and media bypass is dead on Leopard 8

`BYDAutoManager.LOCATION_*` keys return `-10011` (unavailable) and
`MEDIA_CONTENT_CONTROL` is denied to our package on DiLink 5.1. If either
is ever needed again, use standard Android APIs (`LocationManager`,
`NotificationListenerService`) under `lib/features/<name>/` — never the
bypass path.

**Why.** Even though "location via feature ID" would fit the bypass pattern,
the car firmware doesn't expose it. Upstream apps (Waze, Huawei, AMap) all
take the standard-Android path for the same reason.

**When.** Before writing any new location or media-session code. If it
feels like it should go under `core/car/`, rule 2 already tells you no.

## 7. Build configuration is public

Anything shipped in an APK is inspectable. Configuration files hold environment choices and public verification keys; keep private signing material and credentials outside the repository and APK. No hosted token-fetch workflow is required by the standalone app.

## 8. Two-path domains — don't group voice tools across transports

Today's only example is seats: `seat.vent.drv` (UNIT-path, always works)
and `seat.vent.{pass,rl,rr}` (AC-binder path, trim-dependent). The binder
variants return typed failures when the service is null; the UNIT variants
return `65535` (inactive).

**Why.** A voice `seat_vent_control` group covering both transports would
hide the feature-detection signal — a rear-vent request on a trim that
doesn't ship one would silently succeed at the protocol level and do
nothing physically. Keeping the groups separate means the LLM / tunnel
sees the failure code and can say "that seat isn't ventilated on this
car" instead of "done."

**When.** Any new domain that gets a fallback transport. Expose the two
paths as distinct registry ids, route each through a dedicated controller
method, and let the caller choose. Shared voice grouping is fine **within
one transport** only.

## 9. Keep command recipes in the public native tables

Vehicle write recipes live in android/app/src/main/assets/offline/car_table.textproto and mini_app_table.textproto. Keep runtime call sites on registry IDs and typed SDK APIs instead of duplicating numeric feature IDs or bypassing argument/model/scope checks. Rebuild the APK after editing verified table rows and run the native resource/parity tests. The release preparation helper validates these resources; it does not encrypt or generate them.

## 10. Rate-class declarations override prefix heuristics

`RateLimiter.classify(commandId)` guesses a bucket from the id prefix
(`door.` → actuator, `climate.` → climate, etc.). When the prefix would
land in the wrong bucket, declare `rateClass` explicitly on the
`CarCommand`.

**Why.** The router calls `limiter.tryAdmit(id, override: cmd?.rateClass)`
— explicit wins. An actuator command sitting under a non-actuator prefix
(a climate-namespaced seat release, say) would otherwise burn through
the 30/10s climate budget instead of the stricter 10/10s actuator one,
and a rogue shell could spam it without tripping the burst observer.

**When.** Any command whose prefix doesn't match its physical nature.
Explicit declaration is a one-line `rateClass: RateClass.actuator` in the
`CarCommand` constructor — cheap insurance.

## 11. `SecureLogger` never sees plaintext

`SecurityBridge.logDispatch` hashes the command id and args (sorted-key
canonical JSON → SHA-256) before the MethodChannel call. Nothing on the
Kotlin side of the logger accepts or stores cleartext. The
`car_command_router_test.dart` "command id + args are hashed" check is
the regression fence.

**Why.** A leaked `events/*.bin` file must not re-expose the protocol. A
rooted user holding one week of their own dispatch history shouldn't
learn a feature ID from it.

**When.** Any new event type. Go through `SecurityBridge` rather than
calling the channel directly; if you're adding a new event shape, hash
sensitive fields in the bridge, not at the call site, so callers can't
forget.

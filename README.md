# MillerOBD Serializer

Bench tool for programming MillerOBD **M1** (V015 board) adapters with a signed
per-unit identity. Windows and macOS, one binary each, one device at a time.

Replaces `millerobd_program.py` at `Development/2026/OBDII/Test/`, which
remains the reference implementation for the identity format.

## The flow

Power an adapter up and it is found, connected, and identified. From there:

| What was found | What happens |
|---|---|
| A **Go** | Refused, with the reason. It has no writable storage. |
| **Blank** (all slots FF) | Allocate a serial → write → read back → health check → record |
| A **known** serial | Shown as already programmed, with its record |
| An **unknown** serial | Asks whether to wipe and reprogram |
| A **half-written** identity | Offers erase-and-reprogram with a fresh serial |
| **Enabled** identity slots | Offers `AT PP FF OFF` to repair |

Then **Next Device** — one click, and the Bluetooth transport is rebuilt from
scratch before the next scan.

## Why Next Device throws the transport away

It does not simply disconnect and re-scan. It disposes the whole
`BleTransport` and builds a new one, which is the same recovery
`drivedecode-app` runs behind its Rescan button
(`lib/providers/connection_reset.dart`).

A soft disconnect can only recover state this app owns. It cannot recover the
layer underneath: `universal_ble` serialises every BLE command through a
*process-global* queue with no timeout of its own, so one native call that
never answers starves every later command for the life of the process. That is
the state behind drivedecode's field report — *"sits on Looking for your
adapter even after pressing rescan; the only way to re-find the adapter is to
close the app."* A bench that needs restarting between units is a bench nobody
uses.

Every control that lets go of the adapter runs the same reset: **Next Device**,
the header's **Disconnect**, **Abort**, and the retry that starts over. One
recovery, so there is no second version to drift.

Three ordering rules, all load-bearing and all covered by tests:

1. **Local state first, and it is the only thing awaited.** Cancelling
   subscriptions and closing the ELM session is pure Dart and cannot block.
2. **The old transport is retired before the new scan starts, and is never
   awaited.** Not awaiting is the point — a wedged native queue is exactly the
   state this button gets pressed in, and awaiting a call into it is how the
   button comes to do nothing visible.
3. **No soft `disconnect()` anywhere.** `dispose()` does that and harder — it
   marks the instance dead synchronously, so a teardown still unwinding can
   never touch the radio the new instance now owns.

### The handover, and the bug it fixes

Retiring the old transport is not enough on its own, because
`UniversalBle.disconnect` does **not** return when the platform call returns.
It then waits for a connection *event* to confirm the disconnect, with a
default timeout of **sixty seconds**. So the outgoing transport's `dispose()`
finishes whenever it finishes — routinely seconds after the replacement is
already scanning — and its own final `stopScan` is process-global. It stopped
the scan its successor had started.

Nothing errored. The new scan's subscription was alive and its emit pump was
ticking; the radio was simply off, so no advertisement could ever arrive. The
adapter was also still connected for that whole window, and a connected
peripheral does not advertise. That is "Disconnect is not disconnecting and
Next Device does nothing", from both ends at once.

Two fixes, both in `lib/ble/universal_ble_transport.dart`:

- **A generation counter.** A dying transport stops the radio only while it is
  still the newest one. Once replaced, the replacement owns the radio — and
  calls `stopScan` itself before every `startScan`, so nothing leaks.
- **A five-second disconnect timeout** instead of the library's sixty. The
  platform call is fast; only the confirmation lags, and timing out on the
  confirmation does not undo a disconnect that was already issued.

`drivedecode-app` rarely hits this because its Rescan is usually pressed when
nothing is connected, and a disconnect with no device returns instantly. A
programming bench hits it on *every* unit, because letting go of a live link is
the entire purpose of the button.

A third fix, and the one that actually stopped runs dead: **`connectionState`
is no longer an `async*` generator.** It was:

```dart
Stream<bool> _replaying(BleDevice device) async* {
  yield _linkUp;
  await for (final connected in device.connectionStream) { ... yield connected; }
}
```

which reads correctly and cannot be cancelled. An `async*` only observes
cancellation at a `yield`, and that one spends its life suspended at the
`await for`. On an idle link no event is coming, so it never reaches a `yield`
and `cancel()` **never completes**. The bench awaits exactly that cancel on its
way to the next unit, so Next Device and Disconnect hung before reaching the
transport at all — no teardown, no rebuild, no rescan, no error. Reported as
*"I get to two devices in a session and then it stops"*: two, because
physically swapping the adapter produces a disconnect event, which wakes the
generator and lets that one cancel through by luck.

It is a `StreamController` now, where `onCancel` is called directly by the
stream machinery.

Also: `startScan`'s own teardown is bounded (2s) so a future blocking step
degrades the bench instead of killing it, and every state write from a long
operation carries the unit it belongs to, so a Disconnect pressed midway
through a connect or a program is not undone by work already in the air.

`test/session_soak_test.dart` programs eight units back to back over the real
stack and **times each handover**, because the bound above means a blocking
teardown now costs two seconds a unit rather than failing — which an operator
feels as "the bench got slow" and a naive test would not feel at all.

`test/radio_handover_test.dart` drives the real transport against a fake BLE
platform (`UniversalBle.setInstance`) and reproduces all of this — a fake
`BleTransport` cannot, because what goes wrong is the one piece of state two
transports share.

## The four rules this tool enforces

Each irreversible step happens only after the step that could have prevented
it, and none of them is believed without independent confirmation.

1. **Fingerprint before write.** A Go answers a bare `OK` to commands it has
   not implemented, so a write to one *looks* like it worked. The model is
   settled from the GATT service set before a single command is sent.
2. **Allocate before write, and only from the server.** Two benches computing
   `max(serial)+1` independently mint the same number. If allocation fails,
   nothing has touched the hardware.
3. **Read back before believing.** Neither `OK` nor the absence of `?` is
   evidence a byte was stored. The bytes coming back changed is.
4. **Confirm only after read-back and health both pass.** The database must
   never say `programmed` for a unit whose read-back did not match.

## Identity format

Fixed by hardware already in the field. See `identity-findings.md` in
`drivedecode-app` and `millerobd_identity.py`.

```
AT SD user byte : scheme version (0x01). FF = unprogrammed.
PP 19..1C (4 B) : serial number, uint32 big-endian
PP 1D..23 (7 B) : HMAC bytes 0..6
PP 27..2A (4 B) : HMAC bytes 7..10   -> 88-bit truncated HMAC-SHA256

tag = HMAC-SHA256(key, "MILLEROBD|" + MODEL + "|" + version + serial)[:11]
```

The slots are **disabled** programmable parameters, which is what makes them
inert storage rather than settings the firmware acts on. 24–26 are skipped
because they are functional parameters — that is why the tag is split.

The signing key is a Cloudflare Worker secret and never reaches the bench. The
app writes bytes and reads them back; it cannot mint a tag.

## Setup

### Server (once)

In `dtc-lookup`:

```sh
psql "$SUPABASE_DB_URL" -f sql/012_devices.sql

npx wrangler secret put ADMIN_BENCH_TOKEN        # generate a long random string
npx wrangler secret put MILLEROBD_IDENTITY_KEY   # hex of 2026/OBDII/Test/millerobd.key
npx wrangler deploy
```

The key must be the **same bytes** as `millerobd.key`, hex-encoded, or every
adapter already programmed stops verifying. Get it with:

```sh
python3 -c "print(open('millerobd.key','rb').read().hex())"
```

Both secrets are required: with either missing, `/admin/devices/*` answers 503
rather than accepting anything.

### Bench (per machine)

Launch, open **Settings**, enter the server URL and the admin token. Stored in
`shared_preferences` on that machine only — never in the binary, never in
source. Rotating it is one `wrangler secret put` and one dialog.

Or provision non-interactively:

```sh
flutter run -d macos \
  --dart-define=API_BASE_URL=https://api.millerobd.com \
  --dart-define=ADMIN_BENCH_TOKEN=...
```

## Running

```sh
flutter run   -d macos      # or -d windows
flutter build macos --release
flutter test
```

macOS needs `com.apple.security.device.bluetooth` and
`NSBluetoothAlwaysUsageDescription`; both are already in `macos/Runner/`.
Without them the scan silently finds nothing rather than erroring.

## Offline behaviour

Allocation requires the network, deliberately — inventing serials locally is
the collision the server exists to prevent. An offline bench stops before
touching hardware.

Only *recording* is queued: if `/confirm` fails after a successful write, the
entry lands unconfirmed in `registry.jsonl` (application-support directory) and
is retried at next launch. The success screen says `QUEUED` rather than
`recorded` — **do not ship a unit until it shows as recorded.**

## Layout

```
lib/
  ble/        transport contract + vendored universal_ble implementation
  elm/        ELM327 line protocol, PP read/write/verify
  identity/   slot layout, ATPPS parsing, Go-vs-M1 fingerprint
  api/        Worker client, local journal, settings
  bench/      the state machine and the controller that drives it
  ui/         one window, one exhaustive switch over BenchState
test/
  fake_adapter.dart   scripted M1 and Go behind a fake transport
  fake_server.dart    the Worker's admin endpoints, in memory
```

The BLE layer is **vendored** from `drivedecode-app/lib/data/ble_transport.dart`
rather than depended on, because that file lives in a different git repository.
Three things differ: FFF0/FFF2/FFF1 is a known layout listed first, the
discovered GATT layout is exposed for fingerprinting, and the vehicle-oriented
parts are gone. The scan lifecycle and the epoch/alive radio arbitration are
verbatim — each was written in response to a field failure.

## Before this process is frozen

Persistence is validated on **one** M1 (`identity-findings.md` §6). Program and
power-cycle 3–5 more units before treating the fingerprint or the process as
final. Clone suppliers change firmware between production runs, which is why
the fingerprint evidence is stored per unit rather than only acted on.

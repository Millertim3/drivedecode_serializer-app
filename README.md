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

Then **Next Device** — one click, disconnects and resumes scanning.

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

// lib/elm/programmer.dart
//
// The device operations: read an identity, write one, verify it read back,
// erase, and check the adapter still works afterwards.
//
// A port of the device half of millerobd_program.py. The commands and their
// order are the part that must not drift — they were validated on hardware and
// the results are in identity-findings.md.

import '../identity/identity.dart';
import 'elm_session.dart';

/// What an adapter is carrying, plus the raw evidence it came from.
///
/// The raw dump is kept because it is what an operator needs when a unit
/// behaves oddly, and because [enabledIdentitySlots] is read out of the flags
/// that [DeviceIdentity] deliberately discards.
class IdentityRead {
  const IdentityRead({
    required this.identity,
    required this.ppMap,
    required this.userByte,
    required this.rawPps,
    required this.enabledIdentitySlots,
  });

  final DeviceIdentity identity;
  final Map<String, String> ppMap;
  final String userByte;
  final String rawPps;

  /// Identity slots that came back ENABLED. Always empty on a healthy unit —
  /// see [IdentityReader.enabledSlots] for what a non-empty list means and how
  /// to repair it.
  final List<String> enabledIdentitySlots;

  bool get needsRepair => enabledIdentitySlots.isNotEmpty;
}

/// The outcome of a write, with everything needed to explain a failure.
class WriteResult {
  const WriteResult({
    required this.ok,
    required this.mismatches,
    required this.readBack,
  });

  final bool ok;

  /// slot -> (expected, got). Empty when [ok].
  final Map<String, ({String expected, String got})> mismatches;
  final IdentityRead readBack;

  String describeMismatches() => mismatches.entries
      .map((e) => '${e.key}: wanted ${e.value.expected}, read ${e.value.got}')
      .join('; ');
}

/// Post-write health: the adapter must still be a working ELM327.
///
/// A unit with a perfectly valid identity that no longer negotiates a protocol
/// is a unit that must not ship, and the only moment anyone will notice is
/// right here on the bench.
class HealthCheck {
  const HealthCheck({
    required this.version,
    required this.protocol,
    required this.voltage,
    required this.ok,
  });

  final String version;
  final String protocol;
  final String voltage;
  final bool ok;
}

class AdapterProgrammer {
  AdapterProgrammer(this.session);
  final ElmSession session;

  /// Read the whole identity in two commands.
  ///
  /// ATPPS returns all 48 slots at once — the reason the read is cheap enough
  /// for the shipping app to do on every connect. ATRD reads the one-byte user
  /// memory, which holds the scheme version.
  ///
  /// NOTE what is NOT here: ATMAC. It has timed out at ~5s on every M1 run,
  /// five for five, and it is the source of the ATZZZ oddity in the probe
  /// logs. It buys nothing and costs five seconds a unit.
  Future<IdentityRead> readIdentity() async {
    final pps = await session.send('ATPPS', timeout: ElmSession.ppsTimeout);
    final user = await session.send('ATRD');

    final ppMap = IdentityReader.parsePps(pps.text);
    // Default 'FF' when the adapter gives nothing usable: an ATRD that answers
    // with junk means "no version recorded", which is the same thing an
    // unprogrammed unit means, and parse() treats FF as unprogrammed.
    final userByte = _userByteFrom(user.text);

    return IdentityRead(
      identity: IdentityReader.parse(ppMap, userByte),
      ppMap: ppMap,
      userByte: userByte,
      rawPps: pps.text,
      enabledIdentitySlots: IdentityReader.enabledSlots(pps.text),
    );
  }

  /// Pull the hex byte out of an ATRD reply.
  ///
  /// The reply is normally just `01`, but firmwares vary about echoing and the
  /// Go answers `OK` — which is not hex and correctly falls through to 'FF'.
  static String _userByteFrom(String text) {
    final m = RegExp(r'\b([0-9A-Fa-f]{2})\b').firstMatch(text.trim());
    return m?.group(1)!.toUpperCase() ?? 'FF';
  }

  /// Write an identity and read every byte back.
  ///
  /// THE READ-BACK IS THE WHOLE POINT. Neither `OK` nor the absence of `?` is
  /// evidence that a byte was stored: the Go answers `OK` to commands it has
  /// not implemented and silently ignores ATSD writes, so a bench that trusted
  /// the response would cheerfully report a Go as programmed and file a serial
  /// against a device carrying nothing. The only proof accepted here is the
  /// bytes coming back changed.
  Future<WriteResult> writeIdentity({
    required int serial,
    required String tagHex,
    int version = kSchemeVersion,
  }) async {
    final slots = IdentityReader.slotValues(
      serial: serial,
      tag: IdentityReader.fromHex(tagHex),
    );
    final userValue = version.toRadixString(16).toUpperCase().padLeft(2, '0');

    await session.send('ATSD $userValue');
    for (final entry in slots.entries) {
      // 'AT PP <slot> SV <value>' — Set Value. The parameter stays DISABLED,
      // which is what makes the byte inert storage rather than a setting the
      // firmware will act on.
      await session.send('ATPP ${entry.key} SV ${entry.value}');
    }

    final readBack = await readIdentity();
    final mismatches = <String, ({String expected, String got})>{};
    for (final entry in slots.entries) {
      final got = readBack.ppMap[entry.key];
      if (got != entry.value) {
        mismatches[entry.key] = (expected: entry.value, got: got ?? '--');
      }
    }
    if (readBack.userByte.toUpperCase() != userValue) {
      mismatches['user byte'] =
          (expected: userValue, got: readBack.userByte);
    }

    return WriteResult(
      ok: mismatches.isEmpty,
      mismatches: mismatches,
      readBack: readBack,
    );
  }

  /// Confirm the bytes on the device match a serial and tag we intended.
  ///
  /// Separate from [writeIdentity]'s own check because it answers a different
  /// question: not "did the write land" but "is this unit carrying exactly the
  /// identity the server issued it". Run after a power cycle, it is the proof
  /// the EEPROM held.
  bool matches(IdentityRead read, {required int serial, required String tagHex}) =>
      read.identity.programmed &&
      read.identity.serial == serial &&
      read.identity.tagHex == tagHex.toUpperCase();

  /// Reset every identity slot to FF.
  ///
  /// Used to recover a mis-programmed unit, and by the "wipe and reprogram"
  /// path when an adapter turns up carrying a serial the database has never
  /// heard of. The slots are freely rewritable, so this is a real recovery and
  /// not a scrap.
  Future<WriteResult> eraseIdentity() async {
    await session.send('ATSD FF');
    for (final slot in kAllSlots) {
      await session.send('ATPP $slot SV FF');
    }
    final readBack = await readIdentity();
    final mismatches = <String, ({String expected, String got})>{};
    for (final slot in kAllSlots) {
      final got = readBack.ppMap[slot];
      if (got != 'FF') mismatches[slot] = (expected: 'FF', got: got ?? '--');
    }
    return WriteResult(
      ok: mismatches.isEmpty,
      mismatches: mismatches,
      readBack: readBack,
    );
  }

  /// Turn every programmable parameter back off.
  ///
  /// The repair half of the `AT PP FF ON` risk: a third-party app that enables
  /// all parameters at once enables ours too, and the firmware then starts
  /// acting on bytes that are an HMAC. One command puts it back.
  Future<void> disableAllParameters() => session.send('ATPP FF OFF');

  /// Confirm the adapter is still a working ELM327 after being written to.
  ///
  /// ATI (version), ATDPN (protocol number) and ATRV (voltage). Deliberately
  /// no 0100: there is no vehicle on a bench, so it would fail on a perfectly
  /// healthy unit and the operator would learn nothing. Vehicle-side
  /// confirmation belongs in the hardware runbook, not in a per-unit gate.
  Future<HealthCheck> healthCheck() async {
    final version = await _safe('ATI');
    final protocol = await _safe('ATDPN');
    final voltage = await _safe('ATRV');
    final ok = version.isNotEmpty &&
        version != '?' &&
        protocol.isNotEmpty &&
        protocol != '?';
    return HealthCheck(
      version: version,
      protocol: protocol,
      voltage: voltage,
      ok: ok,
    );
  }

  Future<String> _safe(String command) async {
    try {
      return (await session.send(command)).text.trim();
    } on ElmTimeout {
      return '';
    }
  }
}

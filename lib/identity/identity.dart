// lib/identity/identity.dart
//
// The device identity layout: which programmable-parameter slots hold what,
// how to read an identity back out of an ATPPS dump, and how to render a
// serial for a human.
//
// This is a port of the read half of millerobd_identity.py, which calls itself
// "the single source of truth" and means it. The layout below is fixed by
// hardware already in the field — adapters programmed by the Python tool carry
// exactly these bytes in exactly these slots, and nothing here may drift from
// it.
//
// ---------------------------------------------------------------------
// WHY A DISABLED PROGRAMMABLE PARAMETER IS STORAGE
//
// Each ELM327 PP is a value byte plus an on/off flag, and the firmware "will
// not be able to use this new value until the Programmable Parameter has been
// enabled". So a DISABLED PP is inert: it holds a byte and the firmware acts
// on none of it. All 48 ship disabled on the M1, and fifteen of them accept
// the full 0x00-0xFF range and survive a power cycle. That is where an
// identity lives, because the ELM327 device-identifier feature this was
// supposed to use (AT @2 / AT @3) is unimplemented on the clone firmware —
// AT @2 answers '?'.
//
// ---------------------------------------------------------------------
// WHAT THE APP DOES NOT DO
//
// It does not hold the signing key and it cannot mint a tag. The bench asks
// the Worker for a serial and gets the tag back already computed; the app's
// only cryptographic responsibility is to write those bytes and read them back
// unchanged. That is deliberate — see src/devices.ts in dtc-lookup — and it is
// why there is no HMAC anywhere in this file.

import 'dart:typed_data';

/// Identity scheme version, mirrored into the adapter's AT SD user byte.
const int kSchemeVersion = 0x01;

/// The value an untouched slot reads back as.
const int kUnprogrammed = 0xFF;

/// PP 19..1C — the serial number, uint32 big-endian.
const List<String> kSerialSlots = ['19', '1A', '1B', '1C'];

/// PP 1D..23 and 27..2A — the 11-byte truncated HMAC-SHA256.
///
/// Not contiguous, and the gap is not an oversight: 24, 25, 26 are functional
/// parameters on this firmware. Writing an identity byte into one of those
/// would be storing data in a slot the adapter might act on.
const List<String> kTagSlots = [
  '1D', '1E', '1F', '20', '21', '22', '23', // 0..6
  '27', '28', '29', '2A', //                   7..10
];

/// Every slot the identity occupies, in payload order. Serial first, then tag.
const List<String> kAllSlots = [...kSerialSlots, ...kTagSlots];

/// 88 bits. Not chosen as a security parameter — it is what fits in the
/// eleven writable slots left over after the serial takes four.
const int kTagLength = 11;

const int kMaxSerial = 0xFFFFFFFF;

/// The two adapter models. Only [m1] has writable storage.
enum DeviceModel {
  m1('m1', 'MillerOBD M1'),
  go('go', 'MillerOBD Go');

  const DeviceModel(this.wire, this.label);

  /// The token the server signs with and the database stores.
  final String wire;
  final String label;

  /// Whether this model can carry an identity at all.
  ///
  /// The Go cannot: PP writes are rejected with '?' and ATSD writes are
  /// silently ignored. Worse, it answers a bare `OK` to commands it does not
  /// implement, so a write to a Go LOOKS like it worked. This getter is why
  /// the bench refuses one before writing rather than after.
  bool get isProgrammable => this == DeviceModel.m1;
}

/// What an adapter is currently carrying, as read off the hardware.
class DeviceIdentity {
  const DeviceIdentity({
    required this.programmed,
    required this.partial,
    required this.version,
    required this.serial,
    required this.tag,
  });

  /// True when the adapter carries something. See [IdentityReader.parse] for
  /// what "something" means and why partial writes are not this.
  final bool programmed;

  /// True when SOME identity bytes are set and some are still FF.
  ///
  /// A distinct answer from both "blank" and "programmed", and it has to be:
  /// a write that lost BLE halfway leaves the adapter here, and treating that
  /// as blank would hand it a second serial while the first four bytes of the
  /// old one are still in EEPROM. Recoverable — the slots are freely
  /// rewritable — but only if it is recognised.
  final bool partial;

  final int version;
  final int serial;
  final Uint8List tag;

  String get tagHex => IdentityReader.hex(tag);

  /// The serial as an operator reads it onto a label.
  String get displaySerial => formatSerial(serial);
}

/// The display form: 'MTS' plus eight digits, zero-padded.
///
/// A presentation choice and nothing more. The device stores four raw bytes
/// and the database stores an integer; this prefix exists so a number written
/// on a sticker is recognisably ours and so support can search for it.
String formatSerial(int serial) => 'MTS${serial.toString().padLeft(8, '0')}';

/// Why an identity could not be read.
class IdentityException implements Exception {
  const IdentityException(this.message);
  final String message;
  @override
  String toString() => 'IdentityException: $message';
}

/// Parsing and rendering, with no I/O. Static so the whole thing is trivially
/// testable against the Python module's vectors.
abstract final class IdentityReader {
  /// Parse an `ATPPS` response into {slot: value}, ignoring the on/off flags.
  ///
  /// The response is 48 lines of `19:FF N`. The flag is dropped here because
  /// the value is the payload — but see [enabledSlots], which reads the same
  /// dump for the flags alone, because an ENABLED identity slot is a fault.
  ///
  /// Mirrors parse_pps in millerobd_identity.py, including its tolerance: the
  /// regex finds pairs anywhere in the text, so echoed commands, prompts and
  /// line-ending variation between firmwares cost nothing.
  static Map<String, String> parsePps(String response) {
    final out = <String, String>{};
    final re = RegExp(r'\b([0-9A-Fa-f]{2}):([0-9A-Fa-f]{2})\s*([NFnf])');
    for (final m in re.allMatches(response)) {
      out[m.group(1)!.toUpperCase()] = m.group(2)!.toUpperCase();
    }
    return out;
  }

  /// Identity slots that came back ENABLED (flag 'N').
  ///
  /// Should always be empty. A third-party app that issued `AT PP FF ON` turns
  /// every parameter on at once, including ours — at which point the firmware
  /// starts ACTING on bytes that are an HMAC, and the adapter's behaviour
  /// becomes undefined. `AT PP FF OFF` restores it. This is the detection half
  /// of that repair path.
  static List<String> enabledSlots(String response) {
    final out = <String>[];
    final re = RegExp(r'\b([0-9A-Fa-f]{2}):([0-9A-Fa-f]{2})\s*([NFnf])');
    for (final m in re.allMatches(response)) {
      final slot = m.group(1)!.toUpperCase();
      if (kAllSlots.contains(slot) && m.group(3)!.toUpperCase() == 'N') {
        out.add(slot);
      }
    }
    return out;
  }

  /// Extract {version, serial, tag} from a PPS map. Does not verify the tag —
  /// the app cannot, and must not pretend to.
  ///
  /// UNPROGRAMMED means the user byte is FF *and* every payload byte is FF.
  /// Anything between that and fully-set is [DeviceIdentity.partial]: see the
  /// note on that field for why the distinction is load-bearing.
  static DeviceIdentity parse(Map<String, String> ppMap, String userByte) {
    final version = int.tryParse(userByte.trim(), radix: 16);
    if (version == null) {
      throw IdentityException('user byte "$userByte" is not hex');
    }

    final missing = kAllSlots.where((s) => !ppMap.containsKey(s)).toList();
    if (missing.isNotEmpty) {
      throw IdentityException('PPS dump is missing slots: ${missing.join(", ")}');
    }

    final payload = Uint8List(kAllSlots.length);
    for (var i = 0; i < kAllSlots.length; i++) {
      final b = int.tryParse(ppMap[kAllSlots[i]]!, radix: 16);
      if (b == null) {
        throw IdentityException('slot ${kAllSlots[i]} is not hex');
      }
      payload[i] = b;
    }

    final blankBytes = payload.every((b) => b == kUnprogrammed);
    final blankVersion = version == kUnprogrammed;
    final allBlank = blankVersion && blankBytes;
    final allSet = !blankVersion && payload.any((b) => b != kUnprogrammed);

    return DeviceIdentity(
      programmed: !allBlank,
      // Neither wholly blank nor coherently set: some slots written, some not.
      partial: !allBlank && !allSet,
      version: version,
      serial: ByteData.view(payload.buffer).getUint32(0, Endian.big),
      tag: Uint8List.sublistView(payload, 4),
    );
  }

  /// The bytes to write for a serial and tag the server just minted.
  ///
  /// Returns {slot: 'XX'} for all fifteen PP slots. The user byte is separate
  /// because it is written with a different command (`AT SD`, not `AT PP`) and
  /// keeping it out of this map means a caller cannot accidentally send it to
  /// the wrong one.
  ///
  /// Mirrors build_slot_values in millerobd_identity.py minus the signing.
  static Map<String, String> slotValues({
    required int serial,
    required Uint8List tag,
  }) {
    if (serial < 0 || serial > kMaxSerial) {
      throw IdentityException('serial $serial is outside uint32');
    }
    if (tag.length != kTagLength) {
      throw IdentityException('tag must be $kTagLength bytes, got ${tag.length}');
    }
    final payload = Uint8List(kAllSlots.length);
    ByteData.view(payload.buffer).setUint32(0, serial, Endian.big);
    payload.setRange(4, 4 + kTagLength, tag);
    return {
      for (var i = 0; i < kAllSlots.length; i++)
        kAllSlots[i]: payload[i].toRadixString(16).toUpperCase().padLeft(2, '0'),
    };
  }

  /// The all-FF map that erases an identity.
  static Map<String, String> erasedValues() =>
      {for (final s in kAllSlots) s: 'FF'};

  static Uint8List fromHex(String hex) {
    final clean = hex.trim().toUpperCase();
    if (clean.length.isOdd || !RegExp(r'^[0-9A-F]*$').hasMatch(clean)) {
      throw IdentityException('"$hex" is not hex');
    }
    return Uint8List.fromList([
      for (var i = 0; i < clean.length; i += 2)
        int.parse(clean.substring(i, i + 2), radix: 16),
    ]);
  }

  static String hex(Uint8List bytes) => bytes
      .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
      .join();
}

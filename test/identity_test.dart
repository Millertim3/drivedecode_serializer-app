// The identity layout, against vectors from millerobd_identity.py.
//
// The serial and tag for M1 #001 appear in four places now: this file,
// dtc-lookup/test/devices.test.ts, sql/012_devices.sql's seed row, and
// 2026/OBDII/Test/registry.jsonl. That repetition is deliberate — it is a
// conformance vector, and a layout change that broke every adapter in the
// field would have to be made four times before it went unnoticed.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:millerobd_serializer/identity/identity.dart';

/// M1 #001, from registry.jsonl.
const vectorSerial = 1000;
const vectorTag = 'C7A4F52A435C24A85EDF92';

/// The slot map millerobd_identity.build_slot_values() produces for it.
const vectorSlots = {
  '19': '00', '1A': '00', '1B': '03', '1C': 'E8',
  '1D': 'C7', '1E': 'A4', '1F': 'F5', '20': '2A', '21': '43', '22': '5C',
  '23': '24', '27': 'A8', '28': '5E', '29': 'DF', '2A': '92',
};

/// A full 48-slot ATPPS dump with [overrides] applied, everything else FF.
String ppsDump({Map<String, String> overrides = const {}, String flag = 'F'}) {
  final b = StringBuffer();
  for (var i = 0; i < 0x30; i++) {
    final slot = i.toRadixString(16).toUpperCase().padLeft(2, '0');
    final value = overrides[slot] ?? 'FF';
    final f = overrides.containsKey(slot) ? flag : 'F';
    b.writeln('$slot:$value $f');
  }
  return b.toString();
}

void main() {
  group('slot layout', () {
    test('is fifteen slots: four for the serial, eleven for the tag', () {
      expect(kSerialSlots.length, 4);
      expect(kTagSlots.length, kTagLength);
      expect(kAllSlots.length, 15);
    });

    /// 24, 25 and 26 are FUNCTIONAL parameters on this firmware. An identity
    /// byte in one of those would be data in a slot the adapter might act on,
    /// and the gap between 23 and 27 is the reason the tag is split.
    test('skips the functional parameters between 23 and 27', () {
      expect(kTagSlots, isNot(contains('24')));
      expect(kTagSlots, isNot(contains('25')));
      expect(kTagSlots, isNot(contains('26')));
    });

    test('produces the Python tool\'s exact slot map for M1 #001', () {
      final slots = IdentityReader.slotValues(
        serial: vectorSerial,
        tag: IdentityReader.fromHex(vectorTag),
      );
      expect(slots, vectorSlots);
    });

    test('encodes the serial big-endian', () {
      final slots = IdentityReader.slotValues(
        serial: 0x01020304,
        tag: Uint8List(kTagLength),
      );
      expect([slots['19'], slots['1A'], slots['1B'], slots['1C']],
          ['01', '02', '03', '04']);
    });

    test('refuses a tag that is not eleven bytes', () {
      expect(
        () => IdentityReader.slotValues(serial: 1, tag: Uint8List(10)),
        throwsA(isA<IdentityException>()),
      );
    });
  });

  group('reading an ATPPS dump', () {
    test('round-trips a programmed identity', () {
      final read = IdentityReader.parse(
          IdentityReader.parsePps(ppsDump(overrides: vectorSlots)), '01');
      expect(read.programmed, isTrue);
      expect(read.partial, isFalse);
      expect(read.serial, vectorSerial);
      expect(read.tagHex, vectorTag);
      expect(read.version, kSchemeVersion);
      expect(read.displaySerial, 'MTS00001000');
    });

    test('reads an untouched adapter as unprogrammed', () {
      final read = IdentityReader.parse(IdentityReader.parsePps(ppsDump()), 'FF');
      expect(read.programmed, isFalse);
      expect(read.partial, isFalse);
    });

    /// The signature of a write that lost its connection halfway. Neither
    /// blank nor programmed — and calling it blank would issue a second serial
    /// over the remains of a first.
    test('reads a half-written adapter as partial, not blank', () {
      final half = Map<String, String>.from(vectorSlots)
        ..removeWhere((k, _) => kTagSlots.contains(k));
      final read =
          IdentityReader.parse(IdentityReader.parsePps(ppsDump(overrides: half)), 'FF');
      expect(read.programmed, isTrue, reason: 'bytes are set — not blank');
      expect(read.partial, isTrue);
    });

    test('tolerates echoed commands and prompts around the dump', () {
      final noisy = 'ATPPS\r${ppsDump(overrides: vectorSlots)}\r>';
      final read = IdentityReader.parse(IdentityReader.parsePps(noisy), '01');
      expect(read.serial, vectorSerial);
    });

    test('refuses a truncated dump rather than inventing bytes', () {
      expect(
        () => IdentityReader.parse({'19': '00'}, '01'),
        throwsA(isA<IdentityException>()),
      );
    });
  });

  group('the enabled-parameter fault', () {
    /// A third-party app issuing `AT PP FF ON` enables every parameter,
    /// including ours — at which point the firmware starts acting on bytes
    /// that are an HMAC.
    test('spots identity slots that came back enabled', () {
      final dump = ppsDump(overrides: vectorSlots, flag: 'N');
      expect(IdentityReader.enabledSlots(dump), containsAll(kAllSlots));
    });

    test('is silent on a healthy adapter', () {
      expect(IdentityReader.enabledSlots(ppsDump(overrides: vectorSlots)),
          isEmpty);
    });

    /// An unrelated functional parameter being enabled is normal and must not
    /// raise the alarm.
    test('ignores enabled slots outside the identity range', () {
      final dump = ppsDump(overrides: {'2F': '0A'}, flag: 'N');
      expect(IdentityReader.enabledSlots(dump), isEmpty);
    });
  });

  group('display', () {
    test('pads to the MTS label format', () {
      expect(formatSerial(1000), 'MTS00001000');
      expect(formatSerial(1043), 'MTS00001043');
    });
  });

  group('models', () {
    test('only the M1 is programmable', () {
      expect(DeviceModel.m1.isProgrammable, isTrue);
      expect(DeviceModel.go.isProgrammable, isFalse);
    });
  });
}

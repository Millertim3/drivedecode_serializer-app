// lib/identity/fingerprint.dart
//
// Telling a MillerOBD M1 from a MillerOBD Go, before anything is written.
//
// ---------------------------------------------------------------------
// WHY THIS EXISTS AT ALL
//
// The Go has no writable storage. PP writes are rejected, ATSD writes are
// silently ignored — and, the part that makes this a safety check rather than
// a convenience, IT ANSWERS A BARE `OK` TO COMMANDS IT HAS NOT IMPLEMENTED.
// A bench that wrote first and asked questions later would send fifteen PP
// writes to a Go, receive fifteen agreeable replies, and burn a serial on a
// device carrying nothing.
//
// The read-back in AdapterProgrammer.writeIdentity is the backstop and it
// catches this. But catching it there means a serial has already been
// allocated and a device has already been written to, and the operator gets a
// failure instead of an explanation. Fingerprinting first turns that into
// "this is a Go — it cannot be programmed", which is a different and much
// better thing to put on a screen.
//
// ---------------------------------------------------------------------
// WHY THE NAIVE SIGNALS ARE ABSENT
//
// Both models report the identical version string (`ELM327 v1.5`), the
// identical device description, and the identical supported-command count.
// Neither answers any vendor command. Everything that actually separates them
// is below, and signal 1 does most of the work.
//
// fingerprint_v1 is explicitly PROVISIONAL: it was frozen against one M1 and
// one Go, and clone suppliers change firmware between production runs. That is
// why the evidence is recorded to the database alongside the verdict rather
// than merely acted on — when v2 becomes necessary, the v1 evidence for every
// unit ever programmed is still there to re-score.

import '../ble/transport.dart';
import '../elm/elm_session.dart';
import 'identity.dart';

/// The evidence behind a model verdict, and the verdict.
class Fingerprint {
  const Fingerprint({
    required this.model,
    required this.confident,
    required this.serviceUuids,
    required this.fff1Properties,
    required this.atrd,
    required this.atcs,
    required this.signals,
  });

  /// Null when the evidence fits neither model.
  final DeviceModel? model;

  /// Whether the corroborating signals agreed with the GATT verdict.
  ///
  /// An unconfident M1 verdict is still an M1 verdict — the GATT set is the
  /// signal a substituted board would have to fake wholesale — but it is worth
  /// showing the operator, because it is how a firmware change first surfaces.
  final bool confident;

  final Set<String> serviceUuids;
  final Set<String> fff1Properties;
  final String atrd;
  final String atcs;

  /// Human-readable per-signal outcomes, for the log panel and the database.
  final List<String> signals;

  /// The shape stored in licensing.devices.fingerprint.
  Map<String, dynamic> toJson() => {
        'version': 'fingerprint_v1',
        'model': model?.wire,
        'confident': confident,
        'ble_services': serviceUuids.toList()..sort(),
        'fff1_properties': fff1Properties.toList()..sort(),
        'atrd': atrd,
        'atcs': atcs,
        'signals': signals,
      };
}

/// Probe an already-connected adapter and decide what it is.
///
/// Order is deliberate: the GATT set is already in hand from connect, so the
/// verdict is reached before a single command is sent, and the AT probes only
/// corroborate it.
Future<Fingerprint> fingerprintAdapter({
  required GattLayout? gatt,
  required ElmSession session,
}) async {
  final services = gatt?.serviceUuids ?? const <String>{};
  final fff1 = gatt?.characteristic('fff1');
  final fff1Props = fff1?.properties ?? const <String>{};
  final signals = <String>[];

  // --- Signal 1: the GATT service set ------------------------------------
  //
  // The best signal by a distance, and the only one required to match. The M1
  // exposes Tx Power (1804) and Battery (180F) alongside the vendor service;
  // the Go exposes the vendor service alone. Checkable before any command, and
  // a substituted board would have to reproduce the whole layout.
  final hasVendor = services.contains('fff0');
  final hasM1Extras = services.contains('1804') && services.contains('180f');

  DeviceModel? model;
  if (hasVendor && hasM1Extras) {
    model = DeviceModel.m1;
    signals.add('GATT: 1804 + 180F + FFF0 — M1 layout');
  } else if (hasVendor && !hasM1Extras) {
    model = DeviceModel.go;
    signals.add('GATT: FFF0 alone — Go layout');
  } else {
    signals.add('GATT: no FFF0 vendor service — not a MillerOBD adapter');
  }

  // --- Signal 2: FFF1 properties -----------------------------------------
  //
  // The M1's notify characteristic is readable; the Go's is writable. Read
  // from the same discovery, so it costs nothing.
  if (fff1 != null) {
    signals.add('FFF1: ${(fff1Props.toList()..sort()).join(", ")}');
  }

  // --- Signals 3 and 5: behavioural corroboration ------------------------
  //
  // ATRD returns a real hex byte on the M1 and a bare `OK` on the Go. ATCS
  // returns 'T:00 R:00' on the M1 and `OK` on the Go. Both are cheap, and both
  // are exactly the "answers OK to things it has not implemented" behaviour
  // that makes the Go dangerous to write to.
  //
  // NOT probed: PP write acceptance (signal 4). It is the strongest
  // behavioural signal and it is a WRITE — using it to decide whether writing
  // is safe would be the thing it is meant to prevent.
  final atrd = await _probe(session, 'ATRD');
  final atcs = await _probe(session, 'ATCS');

  var corroborating = 0;
  final atrdIsHex = RegExp(r'^[0-9A-Fa-f]{2}$').hasMatch(atrd.trim());
  final atcsIsPattern =
      RegExp(r'^T:[0-9A-F]{2} R:[0-9A-F]{2}$', caseSensitive: false)
          .hasMatch(atcs.trim());

  if (model == DeviceModel.m1) {
    if (atrdIsHex) {
      corroborating++;
      signals.add('ATRD: "$atrd" — real byte, consistent with M1');
    } else {
      signals.add('ATRD: "$atrd" — expected a hex byte for an M1');
    }
    if (atcsIsPattern) {
      corroborating++;
      signals.add('ATCS: "$atcs" — consistent with M1');
    } else {
      signals.add('ATCS: "$atcs" — expected T:xx R:xx for an M1');
    }
    if (fff1Props.contains('read')) {
      corroborating++;
      signals.add('FFF1 is readable — consistent with M1');
    }
  } else if (model == DeviceModel.go) {
    if (!atrdIsHex) corroborating++;
    if (!atcsIsPattern) corroborating++;
    signals.add('ATRD: "$atrd", ATCS: "$atcs" — consistent with Go');
  }

  return Fingerprint(
    model: model,
    // Two of three corroborating signals. fingerprint_v1's own rule is "three
    // of signals 3-7", but two of those seven are the PP write this
    // deliberately does not perform and a latency measurement that varies by
    // host BLE stack — so the threshold is scaled to the signals actually
    // gathered rather than left nominally higher and quietly unreachable.
    confident: model != null && corroborating >= 2,
    serviceUuids: services,
    fff1Properties: fff1Props,
    atrd: atrd,
    atcs: atcs,
    signals: signals,
  );
}

Future<String> _probe(ElmSession session, String command) async {
  try {
    return (await session.send(command)).text.trim();
  } on ElmTimeout {
    return '(timeout)';
  }
}

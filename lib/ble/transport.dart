// lib/ble/transport.dart
//
// The contract the bench speaks to, and the types that cross it. Pure Dart:
// no universal_ble import anywhere in this file, which is what lets the whole
// programming flow be tested against a fake adapter with no radio and no
// hardware.
//
// Lifted from obd_protocol's BleTransport in drivedecode-app, with one
// addition — [gatt]. The app never needed to see the discovered GATT layout;
// the bench does, because the service set is the single best signal for
// telling an M1 from a Go and it is readable before a single AT command is
// sent. See lib/identity/fingerprint.dart.

import 'dart:async';

/// One adapter as the scan currently understands it.
class DiscoveredAdapter {
  const DiscoveredAdapter({
    required this.id,
    required this.name,
    required this.rssi,
  });
  final String id;
  final String name;
  final int rssi;
}

/// What went wrong, in terms the bench screen can render as advice.
enum FailureReason {
  /// Peripheral unreachable, dropped, or never answered.
  outOfRange,

  /// Connected, but not shaped like an ELM327 clone — no UART-style
  /// write/notify pair, or one that refuses the operations a serial bridge
  /// needs.
  incompatibleAdapter,

  /// The ELM stopped answering mid-sequence.
  commandTimeout,

  /// Adapter off, blocked, or unauthorised.
  bluetoothOff,

  /// Platform BLE stack error.
  bleError,
}

class TransportException implements Exception {
  const TransportException(this.reason, this.message);
  final FailureReason reason;
  final String message;
  @override
  String toString() => 'TransportException(${reason.name}): $message';
}

/// One discovered characteristic, flattened to what fingerprinting cares
/// about.
///
/// Property names are lowercase strings rather than an enum because they are
/// compared against the string list in fingerprint_v1, which came out of a
/// Python prober and is meant to stay editable without a Dart change when a
/// new clone firmware turns up.
class GattCharacteristic {
  const GattCharacteristic({required this.uuid, required this.properties});
  final String uuid;
  final Set<String> properties;
}

class GattService {
  const GattService({required this.uuid, required this.characteristics});
  final String uuid;
  final List<GattCharacteristic> characteristics;
}

/// The GATT layout as discovered on the current link.
///
/// Captured at connect and held until the next one. The M1 exposes 1804 Tx
/// Power + 180F Battery + FFF0; the Go exposes FFF0 alone. That difference is
/// checkable before any command is sent and a substituted board would have to
/// match the whole layout to fake it, which is why it outranks every
/// behavioural signal.
class GattLayout {
  const GattLayout(this.services);
  final List<GattService> services;

  /// The 16-bit short form of every service, lowercased — '1804', 'fff0'.
  ///
  /// Normalised because platforms disagree about what they hand back: macOS
  /// gives '180F' for a SIG service and a full 128-bit string for a vendor
  /// one, Windows gives 128-bit for both. Comparing raw strings across the two
  /// is how a fingerprint would pass on one platform and fail on the other.
  Set<String> get serviceUuids =>
      services.map((s) => shortUuid(s.uuid)).toSet();

  GattCharacteristic? characteristic(String uuid) {
    final want = shortUuid(uuid);
    for (final s in services) {
      for (final c in s.characteristics) {
        if (shortUuid(c.uuid) == want) return c;
      }
    }
    return null;
  }

  /// Reduce a UUID to its comparable form: the 16-bit short code when it sits
  /// in the Bluetooth SIG base range, the full lowercase UUID otherwise.
  static String shortUuid(String uuid) {
    final u = uuid.toLowerCase().replaceAll('-', '');
    if (u.length == 32 &&
        u.startsWith('0000') &&
        u.endsWith('00001000800000805f9b34fb')) {
      return u.substring(4, 8);
    }
    if (u.length == 4) return u;
    if (u.length == 8 && u.startsWith('0000')) return u.substring(4);
    return uuid.toLowerCase();
  }
}

abstract interface class BleTransport {
  /// Adapters matching [deviceName], for as long as the returned stream has a
  /// listener. Implementations stop the radio on cancel.
  Stream<List<DiscoveredAdapter>> scan({required String deviceName});

  /// Connect, discover services, find the UART write/notify pair, subscribe.
  Future<void> connect(String adapterId);

  Future<void> disconnect();

  /// Raw bytes off the notify characteristic — chunks, NOT lines.
  Stream<List<int>> get incoming;

  Future<void> write(List<int> bytes);

  /// Link state from the platform stack, current value replayed to each new
  /// listener.
  Stream<bool> get connectionState;

  /// What the last successful [connect] discovered. Null before one.
  GattLayout? get gatt;

  Future<void> dispose();
}

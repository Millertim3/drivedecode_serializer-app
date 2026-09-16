// test/fake_adapter.dart
//
// A scripted ELM327 behind a fake BleTransport, so the whole programming flow
// runs with no radio and no hardware.
//
// TWO SCRIPTS, AND THE SECOND IS THE IMPORTANT ONE:
//
//   FakeAdapter.m1() — a V015 board. Fifteen PP slots and the user byte accept
//   writes and remember them; the GATT layout carries 1804 + 180F + FFF0.
//
//   FakeAdapter.go() — the entry-price board, modelled on what it ACTUALLY
//   does rather than what it ought to: it answers a bare `OK` to every write
//   and stores nothing. That is the failure this test suite exists for. A
//   bench that trusts responses reports a Go as programmed and files a serial
//   against a device carrying nothing.

import 'dart:async';
import 'dart:convert';

import 'package:millerobd_serializer/ble/transport.dart';

/// A scripted adapter: a map of PP slots, a user byte, and a response table.
class FakeAdapter {
  FakeAdapter({
    required this.model,
    required this.services,
    required this.writable,
    required this.atrd,
    required this.atcs,
  });

  /// A V015 M1: real writable storage, the full GATT layout, real ATRD/ATCS.
  factory FakeAdapter.m1() => FakeAdapter(
        model: 'm1',
        services: _m1Services,
        writable: true,
        atrd: null, // the real user byte is echoed
        atcs: 'T:00 R:00',
      );

  /// A Go: FFF0 alone, and `OK` to everything it has not implemented.
  factory FakeAdapter.go() => FakeAdapter(
        model: 'go',
        services: _goServices,
        writable: false,
        atrd: 'OK',
        atcs: 'OK',
      );

  final String model;
  final List<GattService> services;

  /// Whether PP and ATSD writes actually change anything.
  final bool writable;

  /// A fixed ATRD reply, or null to echo the stored user byte.
  final String? atrd;
  final String atcs;

  /// All 48 slots, all FF, all disabled — an M1's factory state.
  final Map<String, String> pp = {
    for (var i = 0; i < 0x30; i++)
      i.toRadixString(16).toUpperCase().padLeft(2, '0'): 'FF',
  };

  /// Slots whose enable flag is on. Empty on a healthy unit.
  final Set<String> enabled = {};

  String userByte = 'FF';

  /// Every command received, in order. Lets a test assert that a write was
  /// never attempted, which is a stronger claim than "the write failed".
  final List<String> received = [];

  /// Force a slot to reject writes, for the interrupted-write case.
  final Set<String> rejectSlots = {};

  String respond(String command) {
    received.add(command);
    final c = command.trim().toUpperCase();

    if (c.startsWith('AT')) {
      // Setup and display settings.
      if (const ['ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATZ'].contains(c)) return 'OK';

      if (c == 'ATPPS') return _ppsDump();

      if (c == 'ATRD') return atrd ?? userByte;
      if (c == 'ATCS') return atcs;
      if (c == 'ATI') return 'ELM327 v1.5';
      if (c == 'ATDPN') return 'A6';
      if (c == 'ATRV') return '12.4V';

      final sd = RegExp(r'^ATSD ([0-9A-F]{2})$').firstMatch(c);
      if (sd != null) {
        // The Go silently ignores this and still says OK — the exact behaviour
        // that makes response-trusting unsafe.
        if (writable) userByte = sd.group(1)!;
        return 'OK';
      }

      final ppOff = RegExp(r'^ATPP FF OFF$').firstMatch(c);
      if (ppOff != null) {
        enabled.clear();
        return 'OK';
      }

      final sv = RegExp(r'^ATPP ([0-9A-F]{2}) SV ([0-9A-F]{2})$').firstMatch(c);
      if (sv != null) {
        final slot = sv.group(1)!;
        // The Go REJECTS PP writes outright — '?' rather than a phantom OK.
        if (!writable) return '?';
        if (rejectSlots.contains(slot)) return '?';
        pp[slot] = sv.group(2)!;
        return 'OK';
      }

      return '?';
    }
    return 'NO DATA';
  }

  String _ppsDump() {
    final b = StringBuffer();
    final slots = pp.keys.toList()..sort();
    for (final slot in slots) {
      b.writeln('$slot:${pp[slot]} ${enabled.contains(slot) ? "N" : "F"}');
    }
    return b.toString();
  }

  static final _m1Services = [
    const GattService(uuid: '1804', characteristics: [
      GattCharacteristic(uuid: '2a07', properties: {'read'}),
    ]),
    const GattService(uuid: '180f', characteristics: [
      GattCharacteristic(uuid: '2a19', properties: {'read', 'notify'}),
    ]),
    const GattService(uuid: 'fff0', characteristics: [
      GattCharacteristic(uuid: 'fff1', properties: {'notify', 'read'}),
      GattCharacteristic(uuid: 'fff2', properties: {'write'}),
    ]),
  ];

  static final _goServices = [
    const GattService(uuid: 'fff0', characteristics: [
      GattCharacteristic(uuid: 'fff1', properties: {
        'notify',
        'write',
        'writeWithoutResponse',
      }),
    ]),
  ];
}

/// A BleTransport backed by a [FakeAdapter].
class FakeTransport implements BleTransport {
  FakeTransport(this.adapter, {this.adapters = const []});

  FakeAdapter adapter;

  /// What the scan reports.
  final List<DiscoveredAdapter> adapters;

  final _incoming = StreamController<List<int>>.broadcast();
  final _link = StreamController<bool>.broadcast();
  final _buffer = StringBuffer();

  bool connected = false;
  bool disposed = false;

  /// Make the next write throw, for the dropped-link case.
  Object? failNextWrite;

  /// Never finish dispose() — a wedged native BLE queue, which is exactly the
  /// state the operator presses Next Device in. Nothing may await a transport
  /// in this state.
  bool hangDispose = false;

  /// Make dispose() throw. A transport being torn down because something
  /// already went wrong is entitled to fail on the way out.
  Object? disposeError;

  @override
  GattLayout? get gatt => connected ? GattLayout(adapter.services) : null;

  @override
  Stream<List<DiscoveredAdapter>> scan({required String deviceName}) =>
      Stream.value(adapters);

  @override
  Future<void> connect(String adapterId) async {
    connected = true;
    _link.add(true);
  }

  @override
  Future<void> disconnect() async {
    if (!connected) return;
    connected = false;
    _link.add(false);
  }

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Stream<bool> get connectionState async* {
    yield connected;
    yield* _link.stream;
  }

  @override
  Future<void> write(List<int> bytes) async {
    final fail = failNextWrite;
    if (fail != null) {
      failNextWrite = null;
      throw fail;
    }
    _buffer.write(latin1.decode(bytes));
    final text = _buffer.toString();
    if (!text.contains('\r')) return;
    _buffer.clear();

    for (final command in text.split('\r')) {
      if (command.trim().isEmpty) continue;
      final reply = adapter.respond(command);
      // Reply the way a real adapter does: CR-delimited, then the prompt.
      // Delivered asynchronously so the session's completer is genuinely
      // waiting rather than being resolved inside its own write.
      scheduleMicrotask(() {
        if (_incoming.isClosed) return;
        _incoming.add(latin1.encode('$reply\r\r>'));
      });
    }
  }

  @override
  Future<void> dispose() async {
    // Set FIRST and synchronously, matching UniversalBleTransport: marking the
    // instance dead is the part correctness depends on, and everything after
    // it is cleanup nobody is waiting for.
    disposed = true;
    if (hangDispose) return Completer<void>().future;
    final error = disposeError;
    if (error != null) throw error;
    connected = false;
    await _incoming.close();
    await _link.close();
  }
}

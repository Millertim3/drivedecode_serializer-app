// The programming flow, end to end, against a scripted adapter.
//
// THE TEST THAT MATTERS IS THE GO. It has no writable storage and answers a
// bare `OK` to commands it has not implemented, so a bench that trusted
// responses would report one as programmed and file a serial against a device
// carrying nothing. Two independent defences are pinned here:
//
//   1. Fingerprinting stops a Go before a single write is attempted.
//   2. If fingerprinting were bypassed, the read-back still fails.
//
// Either alone is sufficient. Both are asserted, because the first is the one
// that gives the operator an explanation and the second is the one that is
// still true when clone firmware changes and the fingerprint stops matching.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:millerobd_serializer/api/bench_client.dart';
import 'package:millerobd_serializer/ble/transport.dart';
import 'package:millerobd_serializer/bench/bench_controller.dart';
import 'package:millerobd_serializer/bench/bench_state.dart';
import 'package:millerobd_serializer/elm/elm_session.dart';
import 'package:millerobd_serializer/elm/programmer.dart';
import 'package:millerobd_serializer/identity/fingerprint.dart';
import 'package:millerobd_serializer/identity/identity.dart';

import 'fake_adapter.dart';
import 'fake_server.dart';
import 'identity_test.dart' show vectorSerial, vectorTag;

const _adapter = DiscoveredAdapter(id: 'BF7DE026', name: 'OBD BLE', rssi: -50);

/// A controller wired to a fake adapter and a fake server.
///
/// [transports] records every transport the controller builds, in order. The
/// ADAPTER is shared across all of them and the TRANSPORT is new each time,
/// which is the real relationship: the hardware on the bench persists, the
/// object talking to it does not.
class Harness {
  Harness(this.adapter, {FakeServer? server}) : server = server ?? FakeServer() {
    controller = BenchController(
      transportFactory: () {
        final t = FakeTransport(adapter, adapters: const [_adapter]);
        transports.add(t);
        return t;
      },
      client: BenchClient(
        baseUrl: 'https://bench.test',
        adminToken: 'token',
        client: MockClient(this.server.handle),
      ),
    );
  }

  final FakeAdapter adapter;
  final FakeServer server;
  late final BenchController controller;
  final List<FakeTransport> transports = [];

  /// The transport the controller is using now.
  FakeTransport get transport => transports.last;

  /// Get to a connected adapter the way the operator does — the controller
  /// builds its first transport inside startScan, so nothing can connect
  /// before one has run.
  Future<void> connect() async {
    await controller.startScan();
    await controller.connect(_adapter);
  }
}

Harness harness(FakeAdapter adapter, {FakeServer? server}) =>
    Harness(adapter, server: server);

void main() {
  group('the Go — a model that cannot carry an identity', () {
    test('is refused before a single write is attempted', () async {
      final go = FakeAdapter.go();
      final h = harness(go);

      await h.connect();

      expect(h.controller.state, isA<NotProgrammable>());
      final state = h.controller.state as NotProgrammable;
      expect(state.fingerprint.model, DeviceModel.go);
      expect(state.reason, contains('no writable storage'));

      // The claim that matters: nothing was written and no serial was burned.
      // 'ATPP ' with the space, not 'ATPP': ATPPS is the READ, and it is the
      // write commands that must be absent.
      expect(go.received.where((c) => c.startsWith('ATPP ')), isEmpty);
      expect(go.received.where((c) => c.startsWith('ATSD')), isEmpty);
      expect(h.server.allocations, isEmpty);
    });

    /// The backstop. Clone suppliers change firmware between production runs
    /// and fingerprint_v1 was frozen against one unit of each model — so the
    /// day a Go turns up with an M1's GATT layout, this is what still saves
    /// the run.
    test('still fails read-back if fingerprinting is bypassed', () async {
      final go = FakeAdapter.go();
      final transport = FakeTransport(go);
      await transport.connect('x');
      final session = ElmSession(transport);
      await session.initialize();

      final result = await AdapterProgrammer(session).writeIdentity(
        serial: vectorSerial,
        tagHex: vectorTag,
      );

      expect(result.ok, isFalse,
          reason: 'a Go stores nothing, however agreeably it answers');
      expect(result.mismatches.length, greaterThanOrEqualTo(15));
      await session.close();
    });

    /// The specific trap: it says OK to things it has not implemented, so the
    /// response is never evidence.
    test('answers OK to ATSD while storing nothing', () async {
      final go = FakeAdapter.go();
      final transport = FakeTransport(go);
      await transport.connect('x');
      final session = ElmSession(transport);

      final reply = await session.send('ATSD 01');
      expect(reply.isOk, isTrue);
      expect(go.userByte, 'FF', reason: 'the byte never changed');
      await session.close();
    });
  });

  group('the M1 — the happy path', () {
    test('programs, verifies, health-checks and records', () async {
      final m1 = FakeAdapter.m1();
      final h = harness(m1);

      await h.connect();
      expect(h.controller.state, isA<ReadyToProgram>());

      await h.controller.program();

      final state = h.controller.state;
      expect(state, isA<Success>(), reason: _describe(state));
      final success = state as Success;
      expect(success.allocation.serial, 1001);
      expect(success.allocation.displaySerial, 'MTS00001001');
      expect(success.recorded, isTrue);
      expect(success.health.ok, isTrue);
      expect(h.controller.sessionCount, 1);

      // The bytes are really on the device, in the right slots.
      final read = IdentityReader.parse(m1.pp, m1.userByte);
      expect(read.serial, 1001);
      expect(read.tagHex, success.allocation.tagHex);
      expect(read.version, kSchemeVersion);
      expect(read.programmed, isTrue);
      expect(read.partial, isFalse);

      // And the server was told, once, in the right order.
      expect(h.server.allocations, hasLength(1));
      expect(h.server.confirmations, [1001]);
      expect(h.server.failures, isEmpty);
    });

    /// ATMAC has timed out at ~5s on every M1 run, five for five, and buys
    /// nothing. Five seconds a unit across a production run is the whole
    /// difference between a two-minute job and a ten-minute one.
    test('never sends ATMAC', () async {
      final m1 = FakeAdapter.m1();
      final h = harness(m1);
      await h.connect();
      await h.controller.program();
      expect(m1.received, isNot(contains('ATMAC')));
    });

    test('records the fingerprint evidence with the allocation', () async {
      final h = harness(FakeAdapter.m1());
      await h.connect();
      await h.controller.program();

      final fp = h.server.allocations.single['fingerprint'] as Map;
      expect(fp['version'], 'fingerprint_v1');
      expect(fp['model'], 'm1');
      expect(fp['ble_services'], containsAll(['1804', '180f', 'fff0']));
    });
  });

  group('an adapter that already carries a serial', () {
    test('is reported as already programmed when the database knows it', () async {
      final m1 = FakeAdapter.m1();
      final server = FakeServer()..known[vectorSerial] = 'programmed';
      _preprogram(m1, serial: vectorSerial, tagHex: vectorTag);
      final h = harness(m1, server: server);

      await h.connect();

      expect(h.controller.state, isA<AlreadyProgrammed>());
      final state = h.controller.state as AlreadyProgrammed;
      expect(state.record.displaySerial, 'MTS00001000');
      expect(state.record.state, 'programmed');
      // Nothing was written and no new serial taken.
      expect(h.server.allocations, isEmpty);
    });

    test('asks about wiping when the database has never heard of it', () async {
      final m1 = FakeAdapter.m1();
      _preprogram(m1, serial: 4242, tagHex: vectorTag);
      final h = harness(m1); // server knows nothing

      await h.connect();

      expect(h.controller.state, isA<UnknownSerial>());
      expect((h.controller.state as UnknownSerial).read.identity.serial, 4242);
      // Critically: it did NOT wipe on its own initiative.
      expect(m1.received.where((c) => c.contains('SV FF')), isEmpty);
      expect(h.server.allocations, isEmpty);
    });

    test('wipes and reprograms only when told to', () async {
      final m1 = FakeAdapter.m1();
      _preprogram(m1, serial: 4242, tagHex: vectorTag);
      final h = harness(m1);

      await h.connect();
      await h.controller.program(wipeFirst: true);

      expect(h.controller.state, isA<Success>(),
          reason: _describe(h.controller.state));
      expect(IdentityReader.parse(m1.pp, m1.userByte).serial, 1001);
    });

    /// A half-written adapter must not be treated as blank: the old serial's
    /// first bytes are still in EEPROM.
    test('recognises a half-written adapter as partial', () async {
      final m1 = FakeAdapter.m1();
      m1.pp['19'] = '00';
      m1.pp['1A'] = '00';
      m1.pp['1B'] = '10';
      m1.pp['1C'] = '92';
      final h = harness(m1);

      await h.connect();
      expect(h.controller.state, isA<PartiallyProgrammed>());
    });
  });

  group('failure handling', () {
    /// The read-back is the only success signal. A slot that refuses the write
    /// must fail the unit, not pass it.
    test('fails the unit when one slot will not take the write', () async {
      final m1 = FakeAdapter.m1()..rejectSlots.add('1D');
      final h = harness(m1);

      await h.connect();
      await h.controller.program();

      final state = h.controller.state;
      expect(state, isA<Failed>());
      final failed = state as Failed;
      expect(failed.message, contains('Read-back'));
      expect(failed.detail, contains('1D'));
      expect(failed.canRetry, isTrue);
      expect(failed.allocation, isNotNull);

      // The serial was allocated but NOT confirmed. A row that says
      // 'programmed' for a device that is not would be the worst outcome here.
      expect(h.server.confirmations, isEmpty);
    });

    test('retires the serial on abort, and never recycles it', () async {
      final h = harness(FakeAdapter.m1()..rejectSlots.add('1D'));
      await h.connect();
      await h.controller.program();
      await h.controller.abort();

      expect(h.server.failures, [1001]);
      expect(h.controller.state, isA<Scanning>());
    });

    test('reuses the same serial on retry rather than burning another', () async {
      final m1 = FakeAdapter.m1()..rejectSlots.add('1D');
      final h = harness(m1);
      await h.connect();
      await h.controller.program();

      // The slot starts cooperating — an interrupted write, then a good one.
      m1.rejectSlots.clear();
      await h.controller.retry();

      expect(h.controller.state, isA<Success>(),
          reason: _describe(h.controller.state));
      expect((h.controller.state as Success).allocation.serial, 1001);
      expect(h.server.allocations, hasLength(1),
          reason: 'a retry must not take a second serial');
    });

    /// If the bench cannot allocate, it must stop BEFORE touching hardware.
    /// Inventing a serial locally is the collision the server exists to
    /// prevent, dressed up as resilience.
    test('an offline bench never writes to the device', () async {
      final m1 = FakeAdapter.m1();
      final h = harness(m1, server: FakeServer()..offline = true);

      await h.connect();
      await h.controller.program();

      expect(h.controller.state, isA<Failed>());
      expect((h.controller.state as Failed).message, contains('offline'));
      // Reading (ATPPS) is expected — identify runs before program. What must
      // not have happened is a WRITE.
      expect(m1.received.where((c) => c.startsWith('ATPP ')), isEmpty);
      expect(m1.received.where((c) => c.startsWith('ATSD')), isEmpty);
      expect(m1.pp['19'], 'FF');
    });

    /// The write succeeded; only the record failed. The bytes are on the
    /// device, so the unit is programmed — but the operator must be told, or
    /// they will ship a unit the entitlement server has never heard of.
    test('surfaces a confirm failure without claiming the unit is recorded',
        () async {
      final m1 = FakeAdapter.m1();
      final h = harness(m1, server: FakeServer()..failConfirm = true);

      await h.connect();
      await h.controller.program();

      expect(h.controller.state, isA<Success>(),
          reason: _describe(h.controller.state));
      expect((h.controller.state as Success).recorded, isFalse);
      // And the bytes really are on the device.
      expect(IdentityReader.parse(m1.pp, m1.userByte).serial, 1001);
    });

    test('fails the unit when it stops answering after programming', () async {
      final m1 = _MuteAfterWrite();
      final h = harness(m1);

      await h.connect();
      await h.controller.program();

      final state = h.controller.state;
      expect(state, isA<Failed>(), reason: _describe(state));
      expect((state as Failed).message, contains('stopped answering'));
      expect(h.server.confirmations, isEmpty);
    });
  });

  group('the enabled-parameter fault', () {
    test('is caught before the identity is interpreted, and is repairable',
        () async {
      final m1 = FakeAdapter.m1();
      _preprogram(m1, serial: vectorSerial, tagHex: vectorTag);
      m1.enabled.addAll(kAllSlots);
      final h = harness(m1);

      await h.connect();
      expect(h.controller.state, isA<NeedsRepair>());

      await h.controller.repair();
      expect(m1.received, contains('ATPP FF OFF'));
      expect(m1.enabled, isEmpty);
      // Having repaired it, the flow carries on with what it actually found.
      expect(h.controller.state, isA<UnknownSerial>());
    });
  });

  group('fingerprinting', () {
    test('never probes with a write', () async {
      final m1 = FakeAdapter.m1();
      final transport = FakeTransport(m1);
      await transport.connect('x');
      final session = ElmSession(transport);

      await fingerprintAdapter(gatt: transport.gatt, session: session);

      // Signal 4 in fingerprint_v1 is "PP write accepted", and using a write
      // to decide whether writing is safe would be the thing it is meant to
      // prevent.
      expect(m1.received.where((c) => c.contains('SV')), isEmpty);
      expect(m1.pp['19'], 'FF');
      await session.close();
    });

    test('identifies an M1 from its GATT set with corroboration', () async {
      final m1 = FakeAdapter.m1();
      final transport = FakeTransport(m1);
      await transport.connect('x');
      final session = ElmSession(transport);

      final fp = await fingerprintAdapter(gatt: transport.gatt, session: session);
      expect(fp.model, DeviceModel.m1);
      expect(fp.confident, isTrue);
      await session.close();
    });

    test('refuses an adapter with no vendor service at all', () async {
      final other = FakeAdapter(
        model: 'other',
        services: const [
          GattService(uuid: 'ffe0', characteristics: [
            GattCharacteristic(uuid: 'ffe1', properties: {'notify', 'write'}),
          ]),
        ],
        writable: true,
        atrd: 'OK',
        atcs: 'OK',
      );
      final h = harness(other);

      await h.connect();
      expect(h.controller.state, isA<NotProgrammable>());
      expect((h.controller.state as NotProgrammable).reason,
          contains('not one of ours'));
    });
  });

  // =====================================================================
  // Letting go of the adapter
  //
  // Every control that ends a unit rebuilds the BLE transport rather than
  // merely disconnecting it. The reason is universal_ble's process-global
  // command queue: it has no timeout of its own, so one native call that never
  // answers starves every later BLE command for the life of the process. A
  // soft rescan inherits that state; a new transport does not. On a bench that
  // is the difference between a hundred-unit run and restarting the app
  // between units.
  // =====================================================================
  group('Next Device rebuilds the transport', () {
    test('disposes the old transport and scans on a new one', () async {
      final h = harness(FakeAdapter.m1());
      await h.connect();
      final first = h.transport;
      expect(first.connected, isTrue);

      await h.controller.nextDevice();

      expect(h.transports, hasLength(2), reason: 'a fresh instance was built');
      expect(first.disposed, isTrue, reason: 'the old one was retired');
      expect(identical(h.transport, first), isFalse);
      expect(h.controller.state, isA<Scanning>());
    });

    /// Retiring first is what lets the outgoing instance see that it has been
    /// replaced — the generation check in UniversalBleTransport is what
    /// actually keeps it off the radio, and it can only work if the successor
    /// exists by the time the old teardown reaches it.
    ///
    /// The radio handover itself is pinned against a fake BLE platform in
    /// radio_handover_test.dart; this only pins the order the controller does
    /// the two things in.
    test('retires the old transport before the new one scans', () async {
      final order = <String>[];
      final adapter = FakeAdapter.m1();
      var index = 0;
      final controller = BenchController(
        transportFactory: () => _OrderedTransport(adapter, order, index++),
        client: BenchClient(
          baseUrl: 'https://bench.test',
          adminToken: 'token',
          client: MockClient(FakeServer().handle),
        ),
      );

      await controller.startScan();
      order.clear();
      await controller.nextDevice();

      expect(order, contains('dispose#0'));
      expect(order, contains('scan#1'));
      expect(order.indexOf('dispose#0'), lessThan(order.indexOf('scan#1')));
    });

    /// The whole point of not awaiting the teardown. A wedged native queue is
    /// exactly the state the operator presses this button in, and a button
    /// that waits for it is a button that does nothing visible at all.
    test('is not blocked by a teardown that never finishes', () async {
      final h = harness(FakeAdapter.m1());
      await h.connect();
      h.transport.hangDispose = true;

      await h.controller.nextDevice().timeout(const Duration(seconds: 2));

      expect(h.controller.state, isA<Scanning>());
      expect(h.transports, hasLength(2));
    });

    /// A transport being disposed because something already went wrong is
    /// entitled to fail on the way out. There is no caller left to tell.
    test('survives a teardown that throws', () async {
      final h = harness(FakeAdapter.m1());
      await h.connect();
      h.transport.disposeError = StateError('native stack is gone');

      await h.controller.nextDevice();
      await Future<void>.delayed(Duration.zero);

      expect(h.controller.state, isA<Scanning>());
      expect(h.controller.log.join('\n'), contains('teardown failed'));
    });

    /// One recovery, reached from every direction. A second version of this
    /// would be the one nobody was testing.
    test('every control that lets go of the adapter runs the same reset',
        () async {
      for (final act in <Future<void> Function(Harness)>[
        (h) => h.controller.nextDevice(),
        (h) => h.controller.abort(),
        (h) => h.controller.startScan(),
      ]) {
        final h = harness(FakeAdapter.m1());
        await h.connect();
        final before = h.transport;

        await act(h);

        expect(before.disposed, isTrue);
        expect(h.transports, hasLength(2));
      }
    });

    /// The failure path retires the serial AND the transport. Aborting after a
    /// bad unit is the case where the stack is most likely to be wedged.
    test('abort rebuilds the transport as well as retiring the serial',
        () async {
      final h = harness(FakeAdapter.m1()..rejectSlots.add('1D'));
      await h.connect();
      await h.controller.program();
      final before = h.transport;

      await h.controller.abort();

      expect(h.server.failures, [1001]);
      expect(before.disposed, isTrue);
      expect(h.transports, hasLength(2));
    });

    /// Back-to-back units over fresh transports, which is what a production
    /// run actually is.
    test('programs two units in a row over separate transports', () async {
      final h = harness(FakeAdapter.m1());

      await h.connect();
      await h.controller.program();
      expect((h.controller.state as Success).allocation.serial, 1001);

      await h.controller.nextDevice();
      // A blank adapter on the bench again — the next physical unit.
      h.adapter.pp.updateAll((_, __) => 'FF');
      h.adapter.userByte = 'FF';

      await h.controller.connect(_adapter);
      await h.controller.program();

      expect(h.controller.state, isA<Success>(),
          reason: _describe(h.controller.state));
      expect((h.controller.state as Success).allocation.serial, 1002);
      expect(h.controller.sessionCount, 2);
      expect(h.transports, hasLength(2));
      expect(h.transports.first.disposed, isTrue);
    });


    /// Long operations take seconds and the operator is entitled to give up in
    /// the middle of one. Dart futures do not cancel, so the abandoned work
    /// runs to completion anyway — and before the flow stamp it wrote its
    /// result over the screen the operator was now looking at, which is
    /// exactly "I pressed Disconnect and it did nothing".
    test('a Disconnect pressed mid-program is not undone by the work in flight',
        () async {
      final m1 = FakeAdapter.m1();
      final h = harness(m1, server: FakeServer()..allocateDelay =
          const Duration(milliseconds: 80));
      await h.connect();

      final programming = h.controller.program();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The operator gives up while the serial is still being allocated.
      await h.controller.nextDevice();
      expect(h.controller.state, isA<Scanning>());

      await programming;

      expect(h.controller.state, isA<Scanning>(),
          reason: 'abandoned work wrote over the operator\'s screen');
    });

    /// The same, one step earlier: giving up while the adapter is still being
    /// identified.
    test('a Disconnect pressed mid-identify is not undone either', () async {
      final h = harness(FakeAdapter.m1());
      await h.controller.startScan();

      final connecting = h.controller.connect(_adapter);
      await h.controller.nextDevice();

      await connecting;

      expect(h.controller.state, isA<Scanning>());
    });

    /// Nothing can connect before a transport exists, and the controller must
    /// say so rather than dereferencing null.
    test('refuses to connect before the first scan has built a transport',
        () async {
      final h = harness(FakeAdapter.m1());
      await h.controller.connect(_adapter);
      expect(h.controller.state, isA<Failed>());
      expect(h.transports, isEmpty);
    });
  });
}

/// Put a finished identity onto a fake adapter, the way a previous bench
/// session would have left it.
void _preprogram(FakeAdapter a, {required int serial, required String tagHex}) {
  final slots = IdentityReader.slotValues(
      serial: serial, tag: IdentityReader.fromHex(tagHex));
  a.pp.addAll(slots);
  a.userByte = '01';
}

/// An M1 that goes silent once its identity has been written — a unit damaged
/// by the write, which is exactly what the health check is for.
class _MuteAfterWrite extends FakeAdapter {
  _MuteAfterWrite()
      : super(
          model: 'm1',
          services: FakeAdapter.m1().services,
          writable: true,
          atrd: null,
          atcs: 'T:00 R:00',
        );

  bool _written = false;

  @override
  String respond(String command) {
    final c = command.trim().toUpperCase();
    if (c.startsWith('ATPP') && c.contains('SV')) _written = true;
    if (_written && (c == 'ATI' || c == 'ATDPN')) {
      received.add(command);
      return '?';
    }
    return super.respond(command);
  }
}

String _describe(BenchState s) =>
    s is Failed ? 'unexpectedly Failed: ${s.message} — ${s.detail}' : '$s';


/// A transport that records when it is scanned and when it is disposed, so a
/// test can assert the ORDER of the two across an instance swap.
class _OrderedTransport extends FakeTransport {
  _OrderedTransport(super.adapter, this._order, this._index)
      : super(adapters: const [_adapter]);

  final List<String> _order;
  final int _index;

  @override
  Stream<List<DiscoveredAdapter>> scan({required String deviceName}) {
    _order.add('scan#$_index');
    return super.scan(deviceName: deviceName);
  }

  @override
  Future<void> dispose() {
    _order.add('dispose#$_index');
    return super.dispose();
  }
}

// A whole bench session, end to end, over the real BLE stack minus the native
// layer.
//
// Reported from the bench: "every time I get to two devices during a session,
// it stops." A count-dependent failure is by definition invisible to a test
// that programs one unit, which is what every other test here does. So this
// one runs a RUN — connect, identify, program, verify, record, Next Device,
// again — over the real UniversalBleTransport, the real ElmSession, the real
// AdapterProgrammer and the real BenchController, with only the platform
// faked.
//
// If anything in this stack accumulates per unit — a listener, a closed
// stream controller, a subscription nobody cancels, a radio nobody hands over
// — this is where it shows up, and it shows up on the unit where it starts
// mattering rather than as a vague report.


import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:millerobd_serializer/api/bench_client.dart';
import 'package:millerobd_serializer/ble/universal_ble_transport.dart';
import 'package:millerobd_serializer/bench/bench_controller.dart';
import 'package:millerobd_serializer/bench/bench_state.dart';
import 'package:millerobd_serializer/identity/identity.dart';
import 'package:universal_ble/universal_ble.dart';

import 'fake_adapter.dart';
import 'fake_ble_platform.dart';
import 'fake_server.dart';

const _deviceId = 'BF7DE026-1E1C-4CF8-F39A-226D34F530C6';

void main() {
  late FakeBlePlatform platform;
  late FakeServer server;
  late BenchController controller;
  late FakeAdapter adapter;

  setUp(() {
    adapter = FakeAdapter.m1();
    platform = FakeBlePlatform()..adapter = adapter;
    UniversalBle.setInstance(platform);
    server = FakeServer();
    controller = BenchController(
      transportFactory: UniversalBleTransport.new,
      client: BenchClient(
        baseUrl: 'https://bench.test',
        adminToken: 'token',
        client: MockClient(server.handle),
      ),
    );
  });

  Future<void> settle([int ms = 40]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  /// Wait for the scan to surface the adapter, the way an operator waits for
  /// the tile to appear. Fails loudly rather than hanging, because "the picker
  /// never showed anything" is precisely the reported symptom.
  Future<void> waitForAdapter({required int unit}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      platform.advertise(BleDevice(deviceId: _deviceId, name: 'OBD BLE'));
      await settle(60);
      final state = controller.state;
      if (state is Scanning && state.adapters.isNotEmpty) return;
    }
    fail('unit $unit: the adapter never appeared in the scan — '
        'radio scanning=${platform.scanning}, '
        'state=${controller.state.runtimeType}, '
        'last calls=${platform.calls.reversed.take(8).toList()}');
  }

  /// One complete unit, exactly as the bench does it.
  Future<int> programOneUnit({required int unit}) async {
    await waitForAdapter(unit: unit);

    final scanning = controller.state as Scanning;
    await controller.connect(scanning.adapters.single);

    expect(controller.state, isA<ReadyToProgram>(),
        reason: 'unit $unit did not reach ReadyToProgram: '
            '${_describe(controller.state)}');

    await controller.program();
    expect(controller.state, isA<Success>(),
        reason: 'unit $unit failed to program: ${_describe(controller.state)}');

    final serial = (controller.state as Success).allocation.serial;

    // The operator puts the next unit on the bench. Same fake hardware, blank.
    //
    // TIMED, because the failure mode this file was written for degrades
    // rather than stops: BenchController bounds its own teardown, so a step
    // that blocks costs two seconds a unit instead of killing the run
    // outright. An operator feels that as "the bench got slow" and a passing
    // test feels nothing at all, so the deadline is the assertion.
    final handover = DateTime.now();
    await controller.nextDevice();
    final handoverMs = DateTime.now().difference(handover).inMilliseconds;
    expect(handoverMs, lessThan(1000),
        reason: 'unit $unit: Next Device took ${handoverMs}ms — something in '
            'the teardown is blocking and being papered over by its deadline');
    adapter.pp.updateAll((_, __) => 'FF');
    adapter.userByte = 'FF';
    adapter.received.clear();

    return serial;
  }

  /// THE REPORTED FAILURE. Two units is where it was said to stop, so this
  /// runs well past it — a real fulfillment run is dozens.
  test('programs eight units back to back without stopping', () async {
    await controller.startScan();

    final serials = <int>[];
    for (var unit = 1; unit <= 8; unit++) {
      serials.add(await programOneUnit(unit: unit));
    }

    expect(serials, [1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008]);
    expect(controller.sessionCount, 8);
    expect(server.confirmations, serials);
  });

  /// The radio must still be the successor's after every swap. A run that
  /// silently stops scanning looks identical to a run where no adapter was
  /// powered up.
  test('the radio stays with the newest transport all run', () async {
    await controller.startScan();
    for (var unit = 1; unit <= 5; unit++) {
      await programOneUnit(unit: unit);
      await settle(80);
      expect(platform.scanning, isTrue,
          reason: 'the radio was off after unit $unit');
    }
  });

  /// Nothing may accumulate per unit. A listener left on a shared stream, or a
  /// peripheral never released, is how a run degrades instead of failing
  /// outright.
  test('leaves nothing connected between units', () async {
    await controller.startScan();
    for (var unit = 1; unit <= 4; unit++) {
      await programOneUnit(unit: unit);
      await settle(80);
      expect(platform.connected, isEmpty,
          reason: 'the adapter from unit $unit is still connected, so it '
              'cannot advertise for the next one');
    }
  });

  /// The same run, with the bench pressing Next Device on a unit it decided
  /// not to program — a Go, a mistake, a change of mind. The abandoned units
  /// must not poison the ones after them.
  test('survives units that are skipped rather than programmed', () async {
    await controller.startScan();

    for (var unit = 1; unit <= 3; unit++) {
      await waitForAdapter(unit: unit);
      final scanning = controller.state as Scanning;
      await controller.connect(scanning.adapters.single);
      expect(controller.state, isA<ReadyToProgram>(),
          reason: 'skipped unit $unit: ${_describe(controller.state)}');
      await controller.nextDevice();
    }

    // And a real one still works at the end of it.
    await waitForAdapter(unit: 4);
    final scanning = controller.state as Scanning;
    await controller.connect(scanning.adapters.single);
    await controller.program();
    expect(controller.state, isA<Success>(),
        reason: _describe(controller.state));
    expect(IdentityReader.parse(adapter.pp, adapter.userByte).serial, 1001);
  });
}

String _describe(BenchState s) =>
    s is Failed ? 'Failed(${s.message} — ${s.detail})' : '$s';

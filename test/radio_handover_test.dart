// Handing the radio from one transport to the next.
//
// THE BUG THIS FILE EXISTS FOR, reported from the bench as "Disconnect is not
// disconnecting and Next Device does nothing":
//
//   1. Next Device retires the live transport. Its dispose() awaits
//      disconnect() first.
//   2. UniversalBle.disconnect does NOT return when the platform call returns.
//      It then waits for a connection EVENT to confirm the disconnect, with a
//      default timeout of SIXTY SECONDS. So that await outlives the button
//      press by a wide margin.
//   3. Meanwhile the replacement transport starts scanning. The radio is on and
//      belongs to the new instance.
//   4. The confirmation arrives, the old dispose() resumes, and issues its own
//      final stopScan — which is process-global, and stops the scan its
//      successor started seconds ago.
//
// Nothing errors. The new scan's subscription is alive and its pump is
// ticking; the radio is simply off, so no advertisement can ever arrive. The
// adapter is also still connected during that window, and a connected
// peripheral does not advertise — which is the other half of the report.
//
// None of this is reachable through a fake BleTransport, because the thing
// that goes wrong is the one piece of state two transports SHARE. So these
// tests drive the real UniversalBleTransport against a fake platform, and
// assert on the platform's radio.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:millerobd_serializer/ble/transport.dart';
import 'package:millerobd_serializer/ble/universal_ble_transport.dart';
import 'package:universal_ble/universal_ble.dart';

import 'fake_ble_platform.dart';

const _deviceId = 'BF7DE026-1E1C-4CF8-F39A-226D34F530C6';

void main() {
  late FakeBlePlatform platform;

  setUp(() {
    platform = FakeBlePlatform();
    UniversalBle.setInstance(platform);
  });

  /// Let scheduled work (the disconnect confirmation, the scan pump) run.
  Future<void> settle([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  /// A transport with a live link, the state Next Device is pressed in.
  Future<UniversalBleTransport> connected() async {
    final t = UniversalBleTransport();
    await t.connect(_deviceId);
    return t;
  }

  group('a retired transport does not stop its successor’s scan', () {
    /// The exact reported failure, reproduced. Before the fix this leaves
    /// `platform.scanning` false and the bench picker empty forever.
    test('survives a disconnect that confirms after the new scan has started',
        () async {
      platform.disconnectDelay = const Duration(milliseconds: 50);

      final outgoing = await connected();

      // Retire it the way BenchController does: fire and forget.
      final retired = outgoing.dispose();

      // The replacement starts scanning immediately, while the old
      // disconnect is still waiting for its confirmation.
      final incoming = UniversalBleTransport();
      final seen = <String>[];
      final sub = incoming
          .scan(deviceName: 'OBD')
          .listen((a) => seen.addAll(a.map((d) => d.id)));
      await settle();

      expect(platform.scanning, isTrue,
          reason: 'the outgoing transport stopped its successor’s radio');

      // And now let the old teardown finish; it must still keep its hands off.
      await retired;
      await settle();
      expect(platform.scanning, isTrue);

      // The proof that matters to an operator: an advert still gets through
      // after the old transport has finished dying. One emit pump is 250ms.
      platform.advertise(BleDevice(deviceId: _deviceId, name: 'OBD BLE'));
      await settle(400);
      expect(seen, contains(_deviceId),
          reason: 'the radio is on but the scan hears nothing');

      await sub.cancel();
    });

    /// The same window, but the confirmation never arrives at all — a stack
    /// that has stopped answering. The successor must be unaffected.
    test('survives a disconnect that is never confirmed', () async {
      platform.confirmDisconnects = false;
      platform.disconnectDelay = const Duration(milliseconds: 20);

      final outgoing = await connected();
      unawaited(outgoing.dispose());

      final incoming = UniversalBleTransport();
      final sub = incoming.scan(deviceName: 'OBD').listen((_) {});
      await settle(200);

      expect(platform.scanning, isTrue);
      await sub.cancel();
    });

    /// The handover is by generation, so it holds across a whole run rather
    /// than just the first swap. A hundred-unit session is ninety-nine of
    /// these.
    test('holds across repeated swaps', () async {
      platform.disconnectDelay = const Duration(milliseconds: 30);

      BleTransport? previous;
      for (var unit = 0; unit < 5; unit++) {
        if (previous != null) unawaited(previous.dispose());
        final t = UniversalBleTransport();
        previous = t;
        final sub = t.scan(deviceName: 'OBD').listen((_) {});
        await settle();
        expect(platform.scanning, isTrue, reason: 'radio died on unit $unit');
        await sub.cancel();
        await t.connect(_deviceId);
      }
      await settle(120);
    });
  });

  group('the last transport still cleans up after itself', () {
    /// The guard must not become "never stop the radio". A transport with no
    /// successor is the one that has to leave things tidy.
    test('stops the radio when nothing has replaced it', () async {
      final t = UniversalBleTransport();
      final sub = t.scan(deviceName: 'OBD').listen((_) {});
      await settle();
      expect(platform.scanning, isTrue);

      await sub.cancel();
      await t.dispose();
      await settle();

      expect(platform.scanning, isFalse);
    });
  });

  group('the disconnect itself', () {
    /// A connected peripheral does not advertise, so a disconnect that takes a
    /// minute is a minute in which the adapter cannot be found. The default
    /// timeout on UniversalBle.disconnect is sixty seconds; ours is five.
    test('releases the peripheral rather than waiting out the default timeout',
        () async {
      platform.disconnectDelay = const Duration(milliseconds: 30);
      final t = await connected();
      expect(platform.connected, contains(_deviceId));

      await t.dispose();
      await settle();

      expect(platform.connected, isEmpty,
          reason: 'the adapter is still connected and cannot advertise');
    });

    /// A dispose that cannot confirm must still complete, and in a time an
    /// operator would accept — not the sixty seconds the library defaults to.
    test('gives up waiting for an unconfirmed disconnect', () async {
      platform.confirmDisconnects = false;
      final t = await connected();

      final started = DateTime.now();
      await t.dispose().timeout(const Duration(seconds: 8));
      final elapsed = DateTime.now().difference(started);

      expect(elapsed.inSeconds, lessThan(7),
          reason: 'the 60s library default was not overridden');
    });
  });

  // =====================================================================
  // Cancelling the link subscription
  //
  // The bench awaits this on its way to the next unit, so anything that makes
  // it block makes Next Device and Disconnect dead on arrival — no teardown,
  // no rebuild, no rescan, and no error either.
  //
  // It blocked. connectionState was an `async*` generator suspended in an
  // `await for` over the connection stream, and an async* only observes
  // cancellation at a `yield`. On an idle link no event is coming, so the
  // generator never reaches one and the cancel never completes. Reported from
  // the bench as "I get to two devices in a session and then it stops" — two,
  // because physically swapping the adapter produces a disconnect event, which
  // wakes the generator and lets that one cancel through by luck.
  // =====================================================================
  group('the link subscription', () {
    test('cancels promptly on an idle link', () async {
      final t = await connected();
      final sub = t.connectionState.skipWhile((c) => !c).listen((_) {});
      await settle();

      // No connection event will arrive — that is the whole point.
      await sub.cancel().timeout(
            const Duration(seconds: 2),
            onTimeout: () => fail('cancelling the link subscription hung, so '
                'Next Device can never reach the transport'),
          );

      await t.dispose();
    });

    /// The replay is why this stream is not just `device.connectionStream`:
    /// a subscriber that attaches after a successful connect must still be
    /// told the link is up.
    test('replays the current state to a new listener', () async {
      final t = await connected();
      expect(await t.connectionState.first, isTrue);
      await t.dispose();
    });

    /// And it must still deliver a real drop, which is the thing the bench
    /// turns into "the adapter disconnected mid-unit".
    test('still reports a link that drops', () async {
      final t = await connected();
      final seen = <bool>[];
      final sub = t.connectionState.listen(seen.add);
      await settle();

      platform.updateConnection(_deviceId, false);
      await settle();

      expect(seen, containsAllInOrder([true, false]));
      await sub.cancel();
      await t.dispose();
    });
  });
}

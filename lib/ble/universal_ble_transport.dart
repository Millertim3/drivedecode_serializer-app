// lib/ble/universal_ble_transport.dart
//
// The real BleTransport, over universal_ble. The one place this app touches a
// platform BLE stack.
//
// VENDORED from drivedecode-app/lib/data/ble_transport.dart, deliberately
// rather than depended on: that file lives in a different git repository, and
// a relative path dependency across two repos works on exactly one machine.
// The hard-won parts are kept verbatim and commented as such — the scan
// lifecycle, the epoch/alive radio arbitration, the queue unwedging. Those
// were each written in response to a field failure and none of them should be
// simplified here by someone who has not read why they exist.
//
// THREE THINGS DIFFER FROM THE APP'S COPY:
//
//   1. FFF0/FFF2/FFF1 is a KNOWN layout, listed first. The shipping app only
//      ever reaches the M1's real layout through its generic "first writable +
//      first notifiable" fallback, which works but is a guess. The bench is
//      the tool that decides whether a unit ships; it should not be guessing
//      at which characteristic to talk to.
//
//   2. The discovered GATT layout is EXPOSED, as [gatt]. Telling an M1 from a
//      Go starts with the service set, and that is invisible above this file
//      in the app's copy.
//
//   3. The vehicle-oriented parts are gone: there is no adapter memory and no
//      remembered protocol, because the bench never talks to a car.

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;
import 'package:universal_ble/universal_ble.dart';

import 'transport.dart';

/// A candidate UART pair: the characteristic we write commands to, and the one
/// the adapter answers on. Often the same characteristic (FFE1 clones).
typedef Uart = ({BleCharacteristic write, BleCharacteristic notify});

class UartLayout {
  const UartLayout({
    required this.service,
    required this.write,
    required this.notify,
  });
  final String service;
  final String write;
  final String notify;
}

class UniversalBleTransport implements BleTransport {
  UniversalBleTransport();

  /// Diagnostic hook for GATT discovery and characteristic selection. Feeds
  /// the bench log panel, where an operator watching a unit misbehave can see
  /// what was actually discovered.
  static void Function(String)? onTrace;

  // Known UART-style layouts, most-specific first. `service` narrows
  // discovery; write/notify are matched within it.
  //
  // Written as 16-bit shorthand where the SIG defines it. Every UUID that
  // comes back from discovery is normalised to full 128-bit form by
  // BleService / BleCharacteristic's constructors, so all comparisons below go
  // through BleUuidParser.compareStrings rather than `==`.
  static const _knownLayouts = <UartLayout>[
    // The V015 board — our M1. Split characteristics: write on FFF2, notify on
    // FFF1. First because it is the hardware this tool exists to program.
    UartLayout(service: 'fff0', write: 'fff2', notify: 'fff1'),
    // HM-10 / CC254x clones — one combined characteristic.
    UartLayout(service: 'ffe0', write: 'ffe1', notify: 'ffe1'),
    // Nordic UART Service.
    UartLayout(
      service: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
      write: '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
      notify: '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
    ),
  ];

  // Standard SIG services — plumbing, never vendor UART data. Skipped by the
  // fallback characteristic search below.
  static const _genericAccess = '1800';
  static const _genericAttribute = '1801';

  BleDevice? _device;
  BleCharacteristic? _writeChar;
  GattLayout? _gatt;

  /// Who currently owns the radio.
  ///
  /// Dart futures do not cancel, so an abandoned [connect] keeps running to
  /// completion — and the first thing it does after waiting for the adapter is
  /// call [_stopScanQuietly], which stops the radio GLOBALLY. A stale call
  /// landing after a new scan has started kills that scan, and the symptom is
  /// a picker that sits empty forever with no error to explain it.
  ///
  /// Every claim on the transport bumps this. A connect that finds it has
  /// changed unwinds instead of touching anything the new owner is using.
  int _epoch = 0;

  /// Whether this instance is still the bench's transport.
  ///
  /// [_epoch] settles ownership WITHIN one instance; this settles it BETWEEN
  /// instances, and the two are not interchangeable — `stopScan` is
  /// process-global, so an outgoing instance's teardown would otherwise stop
  /// an incoming instance's brand-new scan. An epoch counter cannot see across
  /// instances, so it cannot arbitrate that.
  bool _alive = true;

  bool _writeWithoutResponse = false;
  bool _linkUp = false;

  final _incoming = StreamController<List<int>>.broadcast();
  StreamSubscription<List<int>>? _notifySub;

  // --- tunables --------------------------------------------------------------

  /// How long an adapter may go silent before it drops off the picker.
  static const _forgetAfter = Duration(seconds: 8);

  /// How often the scan pump emits a batch and evicts stale adapters.
  static const _pumpInterval = Duration(milliseconds: 250);

  /// Weight of each new RSSI sample. Low because raw BLE RSSI is very jittery.
  static const _rssiAlpha = 0.3;

  static const _adapterSettleTimeout = Duration(seconds: 6);
  static const _connectTimeout = Duration(seconds: 12);

  /// Bounds on the two scan calls that reach the platform.
  ///
  /// These are OURS and they have to be. universal_ble serialises startScan
  /// and stopScan through a process-global queue using
  /// `queueCommandWithoutTimeout`, which ignores `UniversalBle.timeout`
  /// entirely — and its per-item timeout only begins once an item reaches the
  /// head of the queue, so a native call that never answers starves every BLE
  /// command in the process and none of them time out either. Without these,
  /// one unanswered call is permanent for the life of the process.
  static const _stopScanTimeout = Duration(seconds: 4);
  static const _startScanTimeout = Duration(seconds: 10);

  @override
  GattLayout? get gatt => _gatt;

  // --- adapter readiness -----------------------------------------------------

  /// Platform BLE stacks reject startScan/connect unless the adapter is
  /// powered on, and right after launch CoreBluetooth can sit in
  /// `unknown`/`resetting` briefly before settling. Wait it out, bounded, and
  /// fail with an actionable reason if the adapter is genuinely off.
  Future<void> _ensureAdapterOn() async {
    var state = await _guard(
      'availabilityState',
      UniversalBle.getBluetoothAvailabilityState,
    );

    if (state == AvailabilityState.unknown ||
        state == AvailabilityState.resetting) {
      // An explicit subscription cancelled in the finally, rather than
      // `firstWhere(...).timeout(...)`: those read identically and the latter
      // leaks, because Future.timeout abandons the future without cancelling
      // the subscription underneath it.
      final settled = Completer<AvailabilityState>();
      StreamSubscription<AvailabilityState>? sub;
      Timer? deadline;
      try {
        sub = UniversalBle.availabilityStream.listen((s) {
          if (s == AvailabilityState.unknown ||
              s == AvailabilityState.resetting) {
            return;
          }
          if (!settled.isCompleted) settled.complete(s);
        });
        deadline = Timer(_adapterSettleTimeout, () {
          if (!settled.isCompleted) settled.complete(AvailabilityState.unknown);
        });
        state = await settled.future;
      } finally {
        deadline?.cancel();
        await sub?.cancel();
      }
    }

    if (state != AvailabilityState.poweredOn) {
      throw TransportException(
        FailureReason.bluetoothOff,
        'Bluetooth adapter not ready: $state',
      );
    }
  }

  // --- platform error translation --------------------------------------------

  /// Map a platform BLE failure onto the typed reason the bench screen renders.
  ///
  /// Exhaustive over [UniversalBleErrorCode] on purpose — no `default:`. When
  /// universal_ble adds a code this stops compiling and someone has to decide
  /// what it means, which is the only way a new failure mode does not silently
  /// become "something went wrong".
  @visibleForTesting
  static FailureReason reasonFor(UniversalBleException e) => switch (e.code) {
        UniversalBleErrorCode.deviceDisconnected ||
        UniversalBleErrorCode.deviceNotFound ||
        UniversalBleErrorCode.connectionTimeout ||
        UniversalBleErrorCode.connectionFailed ||
        UniversalBleErrorCode.connectionRejected ||
        UniversalBleErrorCode.connectionTerminated ||
        UniversalBleErrorCode.connectionLimitExceeded ||
        UniversalBleErrorCode.operationTimeout =>
          FailureReason.outOfRange,
        UniversalBleErrorCode.bluetoothNotAvailable ||
        UniversalBleErrorCode.bluetoothNotEnabled ||
        UniversalBleErrorCode.bluetoothNotAllowed ||
        UniversalBleErrorCode.bluetoothUnauthorized =>
          FailureReason.bluetoothOff,
        UniversalBleErrorCode.serviceNotFound ||
        UniversalBleErrorCode.characteristicNotFound ||
        UniversalBleErrorCode.invalidServiceUuid ||
        UniversalBleErrorCode.invalidCharacteristicUuid ||
        UniversalBleErrorCode.characteristicDoesNotSupportRead ||
        UniversalBleErrorCode.characteristicDoesNotSupportWrite ||
        UniversalBleErrorCode
              .characteristicDoesNotSupportWriteWithoutResponse ||
        UniversalBleErrorCode.characteristicDoesNotSupportNotify ||
        UniversalBleErrorCode.characteristicDoesNotSupportIndicate ||
        UniversalBleErrorCode.operationNotSupported ||
        UniversalBleErrorCode.notSupported ||
        UniversalBleErrorCode.notImplemented =>
          FailureReason.incompatibleAdapter,
        // The pairing / encryption group is listed explicitly rather than
        // folded into a catch-all because it is the cluster most likely to
        // show up on Windows: some clones want to be paired in Windows
        // Settings before WinRT will accept GATT writes.
        UniversalBleErrorCode.notPaired ||
        UniversalBleErrorCode.notPairable ||
        UniversalBleErrorCode.alreadyPaired ||
        UniversalBleErrorCode.pairingFailed ||
        UniversalBleErrorCode.pairingCancelled ||
        UniversalBleErrorCode.pairingTimeout ||
        UniversalBleErrorCode.pairingNotAllowed ||
        UniversalBleErrorCode.unpairingFailed ||
        UniversalBleErrorCode.alreadyUnpaired ||
        UniversalBleErrorCode.authenticationFailure ||
        UniversalBleErrorCode.insufficientAuthentication ||
        UniversalBleErrorCode.insufficientAuthorization ||
        UniversalBleErrorCode.insufficientEncryption ||
        UniversalBleErrorCode.insufficientKeySize ||
        UniversalBleErrorCode.protectionLevelNotMet ||
        UniversalBleErrorCode.accessDenied ||
        UniversalBleErrorCode.unknownError ||
        UniversalBleErrorCode.failed ||
        UniversalBleErrorCode.channelError ||
        UniversalBleErrorCode.connectionAlreadyExists ||
        UniversalBleErrorCode.connectionInProgress ||
        UniversalBleErrorCode.illegalArgument ||
        UniversalBleErrorCode.invalidOffset ||
        UniversalBleErrorCode.invalidAttributeLength ||
        UniversalBleErrorCode.invalidPdu ||
        UniversalBleErrorCode.invalidHandle ||
        UniversalBleErrorCode.readFailed ||
        UniversalBleErrorCode.readNotPermitted ||
        UniversalBleErrorCode.writeFailed ||
        UniversalBleErrorCode.writeNotPermitted ||
        UniversalBleErrorCode.writeRequestBusy ||
        UniversalBleErrorCode.invalidAction ||
        UniversalBleErrorCode.operationCancelled ||
        UniversalBleErrorCode.operationInProgress ||
        UniversalBleErrorCode.scanFailed ||
        UniversalBleErrorCode.stoppingScanInProgress ||
        UniversalBleErrorCode.webBluetoothGloballyDisabled =>
          FailureReason.bleError,
      };

  /// Run a platform call, translating anything it throws into a typed
  /// [TransportException]. Without this the raw plugin exceptions escape past
  /// every `on TransportException` above and land in a generic catch, where
  /// out-of-range, a dead link and a stale device id all render identically.
  Future<T> _guard<T>(String what, Future<T> Function() op) async {
    try {
      return await op();
    } on Object catch (e) {
      throw _translate(what, e);
    }
  }

  TransportException _translate(String what, Object e) {
    if (e is TransportException) return e; // already classified
    if (e is UniversalBleException) {
      // The code goes in the message verbatim: [reasonFor] deliberately
      // collapses ~25 codes into bleError, which is right for the headline and
      // useless for working out why a particular adapter will not connect.
      return TransportException(
          reasonFor(e), '$what: ${e.code.name} (${e.message})');
    }
    if (e is TimeoutException) {
      return TransportException(FailureReason.outOfRange, '$what timed out: $e');
    }
    if (e is PlatformException) {
      return TransportException(
          FailureReason.bleError, '$what: ${e.message ?? e.code}');
    }
    // Not defensive padding: universal_ble's characteristic extension throws a
    // bare String when a characteristic has no metaData, and a plain Exception
    // when a subscription is not supported. Neither is matched above.
    return TransportException(FailureReason.bleError, '$what: $e');
  }

  // --- scanning --------------------------------------------------------------

  /// Adapters matching [deviceName], for as long as the returned stream has a
  /// listener.
  ///
  /// AN EXPLICIT CONTROLLER, NOT `async*`, AND THE REASON MATTERS. An `async*`
  /// generator only observes cancellation at a `yield`, and this one has three
  /// awaits before its first — so a cancel arriving during startup could not
  /// be seen. Its `finally` then awaited `close()` on a single-subscription
  /// controller that had never been listened to, and for such a controller
  /// `close()` returns a `done` future that NEVER COMPLETES: the generator
  /// suspended permanently inside its own finally, the radio kept scanning,
  /// and `cancel()` could never complete — so one wedged scan disabled rescan
  /// for the life of the process.
  ///
  /// With a controller, `onCancel` is called directly by the stream machinery
  /// and teardown is an ordinary future.
  @override
  Stream<List<DiscoveredAdapter>> scan({required String deviceName}) {
    // Per-scan, not per-instance: a fresh scan starts with a clean view rather
    // than inheriting smoothing and ordering from an earlier session.
    final seen = <String, _Seen>{};
    var nextOrder = 0;
    var dirty = false;

    StreamSubscription<BleDevice>? adverts;
    Timer? pump;
    var stopped = false;

    late final StreamController<List<DiscoveredAdapter>> out;

    Future<void> teardown() async {
      if (stopped) return;
      stopped = true;
      pump?.cancel();
      pump = null;
      await adverts?.cancel();
      adverts = null;
      onTrace?.call('scan: stopped (${seen.length} seen)');
      // A disposed transport must not touch the radio: stopScan is
      // process-global, so a late teardown here would kill a scan a NEWER
      // instance had already started. See [_alive].
      if (_alive) await _stopScanQuietly();
    }

    Future<void> start() async {
      try {
        onTrace?.call('scan: starting, looking for "$deviceName"');

        // Claim the radio before anything else, so a connect suspended
        // mid-flight aborts rather than stopping the scan we are about to
        // start. See [_epoch].
        _epoch++;
        await _stopScanQuietly();
        if (stopped) return;

        await _ensureAdapterOn();
        if (stopped) return;
        onTrace?.call('scan: adapter ready');

        adverts = UniversalBle.scanStream.listen((device) {
          if (!_matchesName(device, deviceName)) return;
          final prior = seen[device.deviceId];
          if (prior == null) {
            onTrace?.call('scan: found ${device.deviceId} '
                '"${device.name ?? '?'}" ${device.rssi ?? '?'} dBm');
          }
          final raw = device.rssi?.toDouble();
          final rssi = switch ((prior, raw)) {
            (null, final r?) => r,
            (null, null) => 0.0,
            (final p?, final r?) => p.rssi + _rssiAlpha * (r - p.rssi),
            (final p?, null) => p.rssi, // advert with no RSSI — keep the last
          };
          seen[device.deviceId] = _Seen(
            name: device.name?.isNotEmpty == true ? device.name! : deviceName,
            rssi: rssi,
            order: prior?.order ?? nextOrder++,
            lastSeen: DateTime.now(),
          );
          dirty = true;
        });

        // The emission + eviction pump. universal_ble's scanStream emits one
        // advertisement at a time and never retracts, so batching, live RSSI
        // and "drop adapters that stopped advertising" all live here.
        pump = Timer.periodic(_pumpInterval, (_) {
          final cutoff = DateTime.now().subtract(_forgetAfter);
          final before = seen.length;
          seen.removeWhere((_, s) => s.lastSeen.isBefore(cutoff));
          if (!dirty && seen.length == before) return;
          dirty = false;
          if (!out.isClosed) out.add(_snapshot(seen));
        });

        // NO scan timeout, deliberately: a hard stop leaves a stream that
        // looks alive and can never emit again. Scanning for as long as this
        // stream has a listener is also what finds an adapter powered up late
        // — which on a bench is the normal case, since the operator plugs the
        // unit in AFTER the app is open.
        //
        // No name filter pushed to the platform either.
        // ScanFilter.withNamePrefix is a PREFIX match where we need a
        // SUBSTRING one: our own two models advertise as "OBDBLE" and
        // "OBD BLE", and a prefix filter on "OBD" would still match those but
        // stop matching clones like "Vgate OBD". _matchesName is the filter.
        await _guard('startScan', () async {
          try {
            await UniversalBle.startScan().timeout(_startScanTimeout);
          } on TimeoutException {
            _unwedge('startScan');
            throw const TransportException(
              FailureReason.bleError,
              'The Bluetooth stack stopped responding. Try again.',
            );
          }
        });
        if (stopped) return;
        onTrace?.call('scan: radio started');

        // Push an empty list at scan start so the picker has a defined state
        // immediately rather than after the first pump.
        if (!out.isClosed) out.add(const <DiscoveredAdapter>[]);
      } on Object catch (e, s) {
        // Reaching the listener is the whole point. A scan that cannot start
        // is a failure screen with a reason on it, not a spinner.
        onTrace?.call('scan: failed — $e');
        if (!out.isClosed) out.addError(e, s);
        await teardown();
        if (!out.isClosed) await out.close();
      }
    }

    out = StreamController<List<DiscoveredAdapter>>(
      onListen: () => unawaited(start()),
      onCancel: teardown,
    );
    return out.stream;
  }

  /// Fold the working set into the stable, smoothed list the picker shows.
  ///
  /// Ordered by FIRST SEEN, not by signal strength: sorting by strength would
  /// reorder the list several times a second, so a tile could move out from
  /// under a finger mid-click.
  List<DiscoveredAdapter> _snapshot(Map<String, _Seen> seen) {
    final entries = seen.entries.toList()
      ..sort((a, b) => a.value.order.compareTo(b.value.order));
    return [
      for (final e in entries)
        DiscoveredAdapter(
          id: e.key,
          name: e.value.name,
          rssi: e.value.rssi.round(),
        ),
    ];
  }

  bool _matchesName(BleDevice device, String deviceName) {
    final needle = deviceName.toLowerCase();
    final name = (device.name ?? '').toLowerCase();
    final raw = (device.rawName ?? '').toLowerCase();
    return name.contains(needle) || raw.contains(needle);
  }

  Future<void> _stopScanQuietly() async {
    try {
      await UniversalBle.stopScan().timeout(_stopScanTimeout);
    } on TimeoutException {
      _unwedge('stopScan');
    } catch (_) {
      // Stopping a scan that was never running is not a failure worth
      // surfacing.
    }
  }

  /// Last resort for a BLE command queue that has stopped answering.
  ///
  /// `clearQueue` completes everything still pending and removes the queue, so
  /// the next command builds a fresh one. Without it a single unanswered
  /// native call is permanent for the life of the process — which is precisely
  /// how "rescan does nothing until you restart the app" happens.
  ///
  /// The call that was already executing is ORPHANED, not cancelled, and may
  /// still land later. That is why [_alive] and [_epoch] exist.
  void _unwedge(String what) {
    onTrace?.call('scan: $what did not answer — clearing the BLE command queue');
    UniversalBle.clearQueue();
  }

  // --- connect ---------------------------------------------------------------

  @override
  Future<void> connect(String adapterId) async {
    final mine = ++_epoch;

    await _ensureAdapterOn();
    // BEFORE the global stopScan below, which is the point: waiting for the
    // adapter is the long await, and a rescan landing inside it must not have
    // its fresh scan torn down by this stale attempt.
    _abortIfStale(mine);
    await _stopScanQuietly();

    final device = BleDevice(deviceId: adapterId, name: null);
    _device = device;

    await _guard('connect', () => device.connect(timeout: _connectTimeout));
    await _abortIfSuperseded(device, mine);

    // Bigger MTU = fewer BLE fragments per line. Best-effort: universal_ble
    // documents requestMtu as unsupported on Windows and auto-negotiated on
    // Apple, so the call either helps or throws, and throwing costs nothing.
    try {
      await device.requestMtu(517);
    } catch (_) {
      // Fall back to whatever the stack negotiated.
    }

    await _requestFastConnectionInterval(device);

    final services =
        await _guard('discoverServices', () => device.discoverServices());
    _traceLayout(services);

    final candidates = candidatePairs(services);
    if (candidates.isEmpty) {
      await _disconnectQuietly(device);
      throw const TransportException(
        FailureReason.incompatibleAdapter,
        'No UART-style write/notify characteristics found',
      );
    }

    final Uart uart;
    try {
      uart = await _subscribeFirstWorking(device, services, candidates);
    } on Object {
      await _disconnectQuietly(device);
      rethrow;
    }

    // Last gate before anything is published. Everything above this line is
    // local, so a superseded connect unwinds without having touched a field a
    // newer attempt might already own.
    await _abortIfSuperseded(device, mine);

    _writeChar = uart.write;
    _writeWithoutResponse = uart.write.properties
        .contains(CharacteristicProperty.writeWithoutResponse);
    _gatt = _snapshotGatt(services);

    await _notifySub?.cancel();
    _notifySub = uart.notify.onValueReceived.listen(_incoming.add);

    // Set last, once the link is genuinely usable.
    _linkUp = true;
  }

  /// Flatten the discovered services into the platform-free shape
  /// fingerprinting reads. Taken at connect and held until the next one, so a
  /// disconnect does not erase the evidence the bench is about to record.
  GattLayout _snapshotGatt(List<BleService> services) => GattLayout([
        for (final s in services)
          GattService(
            uuid: s.uuid,
            characteristics: [
              for (final c in s.characteristics)
                GattCharacteristic(
                  uuid: c.uuid,
                  properties: c.properties.map((p) => p.name).toSet(),
                ),
            ],
          ),
      ]);

  /// Codes that mean "this link is not encrypted enough yet", as opposed to
  /// "pairing is impossible here". Only these are worth a bond-and-retry:
  /// notPairable, pairingNotAllowed and pairingCancelled are settled answers,
  /// and alreadyPaired means the bond is not what is missing.
  static const _needsBonding = <UniversalBleErrorCode>{
    UniversalBleErrorCode.notPaired,
    UniversalBleErrorCode.authenticationFailure,
    UniversalBleErrorCode.insufficientAuthentication,
    UniversalBleErrorCode.insufficientAuthorization,
    UniversalBleErrorCode.insufficientEncryption,
    UniversalBleErrorCode.insufficientKeySize,
    UniversalBleErrorCode.protectionLevelNotMet,
  };

  @visibleForTesting
  static bool bondingMightFix(UniversalBleErrorCode code) =>
      _needsBonding.contains(code);

  /// Report the discovered GATT layout.
  ///
  /// The single most useful thing to know when an adapter misbehaves, and
  /// invisible everywhere else. One line per characteristic WITH the
  /// properties, because the properties are exactly the claim that turns out
  /// to be false on the adapters this exists for — and because FFF1's
  /// properties are signal 2 of the model fingerprint.
  void _traceLayout(List<BleService> services) {
    final trace = onTrace;
    if (trace == null) return;
    for (final s in services) {
      trace('ble: service ${s.uuid}');
      for (final c in s.characteristics) {
        final props = c.properties.map((p) => p.name).join(',');
        trace('ble:   char ${c.uuid} [$props]');
      }
    }
  }

  /// Subscribe to the first candidate that actually accepts a subscription.
  ///
  /// A characteristic's properties are a claim, not a guarantee: cheap
  /// adapters flag `notify` on a characteristic with no notify descriptor
  /// behind it, and CoreBluetooth only discovers that at subscribe time.
  /// Committing to one candidate means such an adapter fails the entire
  /// connect even when a working characteristic sits beside it.
  ///
  /// The FIRST failure is what gets reported if everything fails — it is the
  /// best-ranked candidate, so it most likely describes the real problem.
  Future<Uart> _subscribeFirstWorking(
    BleDevice device,
    List<BleService> services,
    List<Uart> candidates,
  ) async {
    TransportException? firstFailure;
    for (final candidate in candidates) {
      for (final subscribe in _subscriptionsFor(candidate.notify)) {
        try {
          await _subscribeWithPairing(
              device, services, candidate.notify, subscribe);
          onTrace?.call('ble: subscribed on ${candidate.notify.uuid} '
              '(writing to ${candidate.write.uuid})');
          return candidate;
        } on TransportException catch (e) {
          firstFailure ??= e;
          onTrace?.call(
              'ble: ${candidate.notify.uuid} would not subscribe — ${e.message}');
        }
      }
    }
    throw firstFailure ??
        const TransportException(FailureReason.incompatibleAdapter,
            'No characteristic accepted a subscription');
  }

  /// The subscribe calls worth trying on [c], in preference order. Notify
  /// before indicate: indicate costs an acknowledgement per packet, which on a
  /// half-duplex link is latency for nothing.
  List<Future<void> Function()> _subscriptionsFor(BleCharacteristic c) => [
        if (c.properties.contains(CharacteristicProperty.notify))
          c.notifications.subscribe,
        if (c.properties.contains(CharacteristicProperty.indicate))
          c.indications.subscribe,
      ];

  /// Subscribe; if the peripheral demands an encrypted link first, bond and
  /// try once more.
  ///
  /// Some adapters gate their UART notify characteristic behind encryption, so
  /// the CCCD write is refused until the device is bonded. CoreBluetooth
  /// reports that as insufficientEncryption rather than by raising a pairing
  /// prompt, and because subscribe is the last step before the link is
  /// published, the whole connect then fails generically with a healthy
  /// adapter sitting on the bench.
  ///
  /// Deliberately narrow: only [_needsBonding], and only once.
  Future<void> _subscribeWithPairing(
    BleDevice device,
    List<BleService> services,
    BleCharacteristic notifyChar,
    Future<void> Function() subscribe,
  ) async {
    try {
      await subscribe();
      return;
    } on Object catch (e) {
      // Raw rather than through _guard, because the decision needs the code
      // and _guard's TransportException has already collapsed it.
      if (e is! UniversalBleException || !_needsBonding.contains(e.code)) {
        throw _translate('subscribe', e);
      }
    }

    final serviceUuid = _serviceOf(services, notifyChar);
    await _guard(
      'pair',
      () => device.pair(
        pairingCommand: serviceUuid == null
            ? null
            : BleCommand(service: serviceUuid, characteristic: notifyChar.uuid),
      ),
    );
    await _guard('subscribe after pairing', subscribe);
  }

  /// The service that owns [characteristic], for building a pairing command.
  /// Null rather than a guess: `pair()` accepts a null command and falls back
  /// to the platform's own bonding, which beats naming the wrong service.
  String? _serviceOf(
          List<BleService> services, BleCharacteristic characteristic) =>
      services
          .where((s) => s.characteristics.any(
              (c) => BleUuidParser.compareStrings(c.uuid, characteristic.uuid)))
          .map((s) => s.uuid)
          .firstOrNull;

  /// Ask for the shortest connection interval the platform will give us.
  ///
  /// An ELM exchange is strict half-duplex ping-pong, so the connection
  /// interval — not the bus — sets the ceiling. Programming a unit is fifteen
  /// writes plus a read-back, so this is the difference between a one-second
  /// job and a four-second one across a hundred-unit run.
  ///
  /// ANDROID ONLY, and universal_ble says so itself. CoreBluetooth exposes no
  /// interval control and WinRT does not either, so on the bench's two
  /// platforms this is a no-op — kept because it costs nothing and the day
  /// this tool runs on a tablet it starts mattering.
  Future<void> _requestFastConnectionInterval(BleDevice device) async {
    if (!BleCapabilities.supportsConnectionPriorityApi) return;
    try {
      await UniversalBle.requestConnectionPriority(
        device.deviceId,
        BleConnectionPriority.highPerformance,
      );
    } catch (_) {
      // Keep whatever interval the stack negotiated.
    }
  }

  /// Abort a connect whose handle was released underneath it.
  ///
  /// [disconnect] nulls `_device` and returns; it cannot reach into an await
  /// still in flight here. Without this check that connect runs to completion
  /// and leaves the peripheral connected with no handle left to release it —
  /// and a connected peripheral stops advertising, so the state is invisible
  /// to every later scan and survives until the adapter is unplugged.
  Future<void> _abortIfSuperseded(BleDevice device, int epoch) async {
    if (identical(_device, device) && _epoch == epoch) return;
    if (identical(_device, device)) _device = null;
    await _disconnectQuietly(device);
    throw const TransportException(
      FailureReason.bleError,
      'Connect superseded by a disconnect while in flight',
    );
  }

  /// The same check for the part of [connect] that runs BEFORE a link exists.
  /// Separate because there is no device to release yet — and because the
  /// damage a stale attempt does up there is not a dangling handle but a
  /// global `stopScan` landing on someone else's scan.
  void _abortIfStale(int epoch) {
    if (_epoch == epoch) return;
    throw const TransportException(
      FailureReason.bleError,
      'Connect superseded before the link was opened',
    );
  }

  /// Every write + notify pair worth trying, best first.
  ///
  /// A LIST rather than one choice, because advertised properties are a claim:
  /// clones exist that flag `notify` on a characteristic with no notify
  /// descriptor behind it, and CoreBluetooth only finds out at subscribe time.
  ///
  /// Order is the whole value: known UART layouts first (FFF0 leading, since
  /// that is our board), then same-service fallback pairs, then cross-service
  /// ones. A UART's two halves live in one service, so a cross-service pair is
  /// a last resort rather than a peer.
  @visibleForTesting
  List<Uart> candidatePairs(List<BleService> services) {
    final candidates = <Uart>[];
    void offer(BleCharacteristic? write, BleCharacteristic? notify) {
      if (write == null || notify == null) return;
      if (candidates.any((c) =>
          BleUuidParser.compareStrings(c.write.uuid, write.uuid) &&
          BleUuidParser.compareStrings(c.notify.uuid, notify.uuid))) {
        return;
      }
      candidates.add((write: write, notify: notify));
    }

    for (final layout in _knownLayouts) {
      final service = services
          .where((s) => BleUuidParser.compareStrings(s.uuid, layout.service))
          .firstOrNull;
      if (service == null) continue;
      final write = service.characteristics
          .where((c) =>
              BleUuidParser.compareStrings(c.uuid, layout.write) && _canWrite(c))
          .firstOrNull;
      for (final notify in service.characteristics.where((c) =>
          BleUuidParser.compareStrings(c.uuid, layout.notify) &&
          _canNotify(c))) {
        offer(write, notify);
      }
    }

    // Fallback over vendor services only. Generic Access (0x1800) and Generic
    // Attribute (0x1801) are BLE plumbing, never vendor UART data — and
    // 0x1801's Service Changed characteristic advertises `indicate`, so
    // without this guard it gets offered as a notify candidate (it is
    // discovered first) and the adapter's replies are never heard.
    final vendor = services
        .where((s) =>
            !BleUuidParser.compareStrings(s.uuid, _genericAccess) &&
            !BleUuidParser.compareStrings(s.uuid, _genericAttribute))
        .toList();

    for (final s in vendor) {
      final write = s.characteristics.where(_canWrite).firstOrNull;
      for (final notify in s.characteristics.where(_canNotify)) {
        offer(write, notify);
      }
    }

    final anyWrite =
        vendor.expand((s) => s.characteristics).where(_canWrite).firstOrNull;
    for (final notify
        in vendor.expand((s) => s.characteristics).where(_canNotify)) {
      offer(anyWrite, notify);
    }

    return candidates;
  }

  static bool _canWrite(BleCharacteristic c) =>
      c.properties.contains(CharacteristicProperty.write) ||
      c.properties.contains(CharacteristicProperty.writeWithoutResponse);

  static bool _canNotify(BleCharacteristic c) =>
      c.properties.contains(CharacteristicProperty.notify) ||
      c.properties.contains(CharacteristicProperty.indicate);

  @override
  Future<void> disconnect() async {
    // A connect still in flight no longer owns the transport — see [_epoch].
    _epoch++;
    _linkUp = false;
    await _notifySub?.cancel();
    _notifySub = null;
    _writeChar = null;
    final device = _device;
    _device = null;
    if (device != null) await _disconnectQuietly(device);
  }

  /// Retire this transport for good. Clearing [_alive] first is what makes it
  /// safe: any scan teardown still unwinding will tidy its own timers but will
  /// not call the process-global stopScan. This method stops the radio once,
  /// on the way out, on behalf of all of them.
  @override
  Future<void> dispose() async {
    if (!_alive) return;
    _alive = false;
    _epoch++;
    try {
      await disconnect();
    } catch (_) {
      // Best-effort. We are going away either way.
    }
    // Deliberately after `_alive = false`, and NOT through
    // _stopScanQuietly: nothing awaits this, so a stopScan that never answers
    // can only leak a future rather than block anything — and it must not arm
    // a Timer, because a Timer created here during a widget test's teardown is
    // still pending when the binding checks and fails the test for a reason
    // unrelated to what it was testing.
    unawaited(UniversalBle.stopScan().catchError((Object _) {}));
    await _incoming.close();
  }

  Future<void> _disconnectQuietly(BleDevice device) async {
    try {
      await device.disconnect();
    } catch (_) {
      // Already gone — nothing to do.
    }
  }

  // --- I/O -------------------------------------------------------------------

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> write(List<int> bytes) async {
    final c = _writeChar;
    if (c == null) {
      throw const TransportException(
          FailureReason.bleError, 'Not connected, no write characteristic');
    }
    await _guard(
        'write', () => c.write(bytes, withResponse: !_writeWithoutResponse));
  }

  @override
  Stream<bool> get connectionState {
    final device = _device;
    if (device == null) return const Stream.empty();
    return _replaying(device);
  }

  /// The link state, with the CURRENT value replayed to each new listener.
  ///
  /// The replay is load-bearing and universal_ble does not provide it:
  /// `connectionStream` is a plain view over connection UPDATES with no
  /// initial event. A bench that subscribes after a successful connect would
  /// hear nothing at all, and a guard written to ignore a replayed
  /// "disconnected" then swallows the real drop when it comes.
  ///
  /// [_linkUp] rather than an `await device.isConnected` seed, deliberately:
  /// an async platform round trip here opens a window in which the true state
  /// could change between the read and the subscription.
  Stream<bool> _replaying(BleDevice device) async* {
    yield _linkUp;
    await for (final connected in device.connectionStream) {
      _linkUp = connected;
      yield connected;
    }
  }
}

/// One adapter as the scan currently understands it.
class _Seen {
  const _Seen({
    required this.name,
    required this.rssi,
    required this.order,
    required this.lastSeen,
  });
  final String name;
  final double rssi;
  final int order;
  final DateTime lastSeen;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

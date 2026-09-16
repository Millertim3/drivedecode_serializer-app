// test/fake_ble_platform.dart
//
// A stand-in for the native BLE stack, injected with UniversalBle.setInstance.
//
// This exists to test ONE thing that cannot be tested any other way: the radio
// is process-global, and so is stopScan. A fake BleTransport can model an
// adapter, but not the thing two transports fight over — and the fight is
// where the bug was.
//
// [scanning] is that shared radio. Every startScan turns it on, every stopScan
// turns it off, and [scanGeneration] records who turned it on last, so a test
// can tell "the radio is on" from "the radio is on because MY scan started it".
//
// The disconnect is modelled the way the real one behaves and not the way one
// would assume: UniversalBle.disconnect issues the platform call and then
// waits for a connection EVENT to confirm it. [confirmDisconnects] controls
// whether that event ever arrives, and [disconnectDelay] how long it takes —
// which is the window the bug lived in.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'fake_adapter.dart';

class FakeBlePlatform extends UniversalBlePlatform {
  /// The one radio, shared by every transport in the process.
  bool scanning = false;

  /// Bumped on every startScan, so a test can prove WHICH scan is running.
  int scanGeneration = 0;

  /// Every radio-level call, in order. The assertion surface for handover.
  final List<String> calls = [];

  final Set<String> connected = {};

  /// How long the platform takes to report a disconnect. The real one waits
  /// for a connection event with a sixty-second default timeout; anything
  /// non-zero here reproduces the window.
  Duration disconnectDelay = Duration.zero;

  /// Whether the disconnect event ever arrives at all.
  bool confirmDisconnects = true;

  AvailabilityState availability = AvailabilityState.poweredOn;

  /// The scripted ELM327 behind the write characteristic. When set, a write to
  /// FFF2 is answered on FFF1, which is what makes a full-stack run possible:
  /// the real transport, the real session, the real programmer, and only the
  /// native layer faked.
  FakeAdapter? adapter;

  final _writeBuffer = StringBuffer();

  /// Whether discovery reports the M1's full service set. False models a Go.
  bool m1Layout = true;

  /// The advert pushed to a running scan when [advertise] is called.
  void advertise(BleDevice device) {
    if (!scanning) return; // a stopped radio hears nothing — the whole point
    updateScanResult(device);
  }

  @override
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {
    scanning = true;
    scanGeneration++;
    calls.add('startScan#$scanGeneration');
  }

  @override
  Future<void> stopScan() async {
    calls.add('stopScan');
    scanning = false;
  }

  @override
  Future<bool> isScanning() async => scanning;

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    calls.add('connect');
    connected.add(deviceId);
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    calls.add('disconnect');
    // The platform call returns promptly; the CONFIRMATION is what lags, and
    // UniversalBle.disconnect does not return until it arrives (or its timeout
    // fires). Scheduled rather than awaited, exactly like the real one.
    Future<void>.delayed(disconnectDelay, () {
      connected.remove(deviceId);
      if (confirmDisconnects) updateConnection(deviceId, false);
    });
  }

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async =>
      connected.contains(deviceId)
          ? BleConnectionState.connected
          : BleConnectionState.disconnected;

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async =>
      availability;

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) async =>
      [
        // The M1's real GATT set: Tx Power and Battery alongside the vendor
        // service. Signal 1 of fingerprint_v1, and the thing that separates an
        // M1 from a Go — without these the fingerprint reads Go and nothing
        // downstream is reachable.
        if (m1Layout) ...[
          BleService('1804', [
            BleCharacteristic.withMetaData(
              deviceId: deviceId,
              serviceId: '1804',
              uuid: '2a07',
              properties: const [CharacteristicProperty.read],
              descriptors: const [],
            ),
          ]),
          BleService('180f', [
            BleCharacteristic.withMetaData(
              deviceId: deviceId,
              serviceId: '180f',
              uuid: '2a19',
              properties: const [
                CharacteristicProperty.read,
                CharacteristicProperty.notify,
              ],
              descriptors: const [],
            ),
          ]),
        ],
        // Split characteristics, notify on FFF1 and write on FFF2.
        //
        // withMetaData and not the bare constructor: universal_ble's
        // characteristic extension refuses to subscribe to a characteristic
        // with no metadata ("Characteristic metaData is not preset"), and the
        // real platform populates it during discovery. A fake that skipped it
        // would fail every connect for a reason that has nothing to do with
        // what these tests are about.
        BleService('fff0', [
          BleCharacteristic.withMetaData(
            deviceId: deviceId,
            serviceId: 'fff0',
            uuid: 'fff1',
            properties: const [
              CharacteristicProperty.notify,
              CharacteristicProperty.read,
            ],
            descriptors: const [],
          ),
          BleCharacteristic.withMetaData(
            deviceId: deviceId,
            serviceId: 'fff0',
            uuid: 'fff2',
            properties: const [CharacteristicProperty.write],
            descriptors: const [],
          ),
        ]),
      ];

  @override
  Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty property) async {}

  @override
  Future<void> writeValue(String deviceId, String service,
      String characteristic, Uint8List value, BleOutputProperty p) async {
    final elm = adapter;
    if (elm == null) return;
    _writeBuffer.write(latin1.decode(value));
    final text = _writeBuffer.toString();
    if (!text.contains('\r')) return;
    _writeBuffer.clear();
    for (final command in text.split('\r')) {
      if (command.trim().isEmpty) continue;
      final reply = elm.respond(command);
      // Answered on the NOTIFY characteristic, asynchronously, the way a real
      // adapter does — so the session is genuinely waiting on a completer
      // rather than being resolved inside its own write.
      scheduleMicrotask(() => updateCharacteristicValue(
          deviceId, 'fff1', Uint8List.fromList(latin1.encode('$reply\r\r>')), null));
    }
  }

  @override
  Future<Uint8List> readValue(String deviceId, String service,
          String characteristic, {Duration? timeout}) async =>
      Uint8List(0);

  @override
  Future<Uint8List> readDescriptorValue(String deviceId, String service,
          String characteristic, String descriptor, {Duration? timeout}) async =>
      Uint8List(0);

  @override
  Future<void> writeDescriptorValue(String deviceId, String service,
      String characteristic, String descriptor, Uint8List value) async {}

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async => expectedMtu;

  @override
  Future<int> readRssi(String deviceId) async => -50;

  @override
  Future<void> requestConnectionPriority(
      String deviceId, BleConnectionPriority priority) async {}

  @override
  Future<bool> isPaired(String deviceId) async => true;

  @override
  Future<bool> pair(String deviceId) async => true;

  @override
  Future<void> unpair(String deviceId) async {}

  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async =>
      const [];

  @override
  Future<bool> enableBluetooth() async => true;

  @override
  Future<bool> disableBluetooth() async => true;
}

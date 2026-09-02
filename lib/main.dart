// lib/main.dart
//
// MillerOBD Serializer — the fulfillment bench tool.
//
// One window, one device at a time: power the adapter up, it is found and
// connected, its model and existing identity are read, a serial is allocated
// by the server, written, read back, health-checked, and recorded. Then Next
// Device.
//
// Windows and macOS from one binary, which is the whole reason this is Flutter
// over universal_ble rather than a second SwiftUI app.

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'api/bench_client.dart';
import 'api/registry_journal.dart';
import 'api/settings.dart';
import 'ble/universal_ble_transport.dart';
import 'bench/bench_controller.dart';
import 'ui/bench_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      // Tall rather than wide: the flow is a vertical sequence of steps with a
      // log pinned under it, and a bench monitor is usually shared with
      // something else.
      size: Size(900, 900),
      minimumSize: Size(720, 640),
      title: 'MillerOBD Serializer',
      titleBarStyle: TitleBarStyle.normal,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  final settings = await BenchSettings.load();
  final transport = UniversalBleTransport();
  final controller = BenchController(
    transport: transport,
    client: BenchClient(
      baseUrl: settings.baseUrl,
      adminToken: settings.adminToken,
    ),
    journal: await _openJournal(),
  );

  // The transport's trace hook is static — it has to be, since nothing above
  // it can see a BleService — so it is bridged onto the controller's log here,
  // in the one place that owns both.
  UniversalBleTransport.onTrace = UniversalTrace.emit;

  runApp(SerializerApp(controller: controller));

  // After the first frame: neither of these should delay the window, and the
  // retry in particular can sit on a network timeout.
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await controller.retryPendingConfirmations();
    await controller.startScan(
      error: settings.configured
          ? null
          : 'No server URL or admin token configured — open Settings before '
              'programming anything.',
    );
  });
}

/// The journal is a convenience, not a dependency: a bench that cannot write
/// its own log file should still be able to program units, since the database
/// is the record that matters.
Future<RegistryJournal?> _openJournal() async {
  try {
    return await RegistryJournal.open();
  } catch (_) {
    return null;
  }
}

class SerializerApp extends StatelessWidget {
  const SerializerApp({super.key, required this.controller});

  final BenchController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MillerOBD Serializer',
        debugShowCheckedModeBanner: false,
        theme: benchTheme(),
        home: BenchScreen(controller: controller),
      );
}

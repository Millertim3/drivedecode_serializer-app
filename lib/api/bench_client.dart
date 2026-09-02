// lib/api/bench_client.dart
//
// The four calls the bench makes to the Worker. See dtc-lookup/src/devices.ts
// for the other side.
//
// ---------------------------------------------------------------------
// WHY THE BENCH CANNOT WORK OFFLINE
//
// Allocation is a server call because two benches computing max(serial)+1
// independently mint the same number, and a duplicate serial in the field is
// the exact signal the entitlement server uses to detect a cloned unit. The
// signing key lives there for the same reason: whoever holds it can mint a
// valid identity for any serial, and a bench laptop is the worst place to keep
// something like that.
//
// The consequence is honest and enforced: no network, no programming. What
// does NOT happen is a local fallback that invents serials and reconciles
// later — that is the collision this design exists to prevent, dressed up as
// resilience. Only the RECORDING of an already-successful write is queued
// locally, by RegistryJournal, because by then the bytes are on the device and
// losing the record would be worse than retrying it.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../identity/identity.dart';

/// A serial and the tag the server minted for it.
class Allocation {
  const Allocation({
    required this.serial,
    required this.tagHex,
    required this.version,
    required this.model,
  });

  final int serial;
  final String tagHex;
  final int version;
  final DeviceModel model;

  String get displaySerial => formatSerial(serial);
}

/// What the database already knows about a serial.
class DeviceRecord {
  const DeviceRecord({
    required this.serial,
    required this.model,
    required this.state,
    required this.tagHex,
    required this.allocatedAt,
    required this.programmedAt,
    required this.healthy,
  });

  final int serial;
  final String model;

  /// 'allocated' | 'programmed' | 'failed' | 'erased'.
  final String state;
  final String? tagHex;
  final DateTime? allocatedAt;
  final DateTime? programmedAt;
  final bool? healthy;

  String get displaySerial => formatSerial(serial);

  static DeviceRecord fromJson(Map<String, dynamic> j) => DeviceRecord(
        serial: (j['serial'] as num).toInt(),
        model: j['model'] as String? ?? 'm1',
        state: j['state'] as String? ?? 'allocated',
        tagHex: j['tag'] as String?,
        allocatedAt: DateTime.tryParse(j['allocated_at'] as String? ?? ''),
        programmedAt: DateTime.tryParse(j['programmed_at'] as String? ?? ''),
        healthy: j['healthy'] as bool?,
      );
}

/// A call the Worker refused, or one that never reached it.
class BenchApiException implements Exception {
  const BenchApiException(this.message, {this.status, this.offline = false});
  final String message;
  final int? status;

  /// True when the request never got an answer at all. The bench screen says
  /// something different for this — "the bench is offline" is actionable,
  /// "server said 409" is not the same problem.
  final bool offline;

  @override
  String toString() => message;
}

class BenchClient {
  BenchClient({
    required this.baseUrl,
    required this.adminToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String adminToken;
  final http.Client _client;

  static const _timeout = Duration(seconds: 15);

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        'X-Admin-Token': adminToken,
      };

  /// Whether the bench is configured at all. A missing token is a setup
  /// problem, not a network one, and saying so saves an operator from
  /// debugging their wifi.
  bool get configured => baseUrl.isNotEmpty && adminToken.isNotEmpty;

  /// Allocate the next serial and get its minted tag.
  ///
  /// The fingerprint travels with the request and is stored against the row.
  /// fingerprint_v1 is provisional; keeping the evidence means a future
  /// revision can re-score every unit ever programmed instead of starting over.
  Future<Allocation> allocate({
    required DeviceModel model,
    String? bleAddress,
    Map<String, dynamic>? fingerprint,
  }) async {
    final body = await _post('/admin/devices/allocate', {
      'model': model.wire,
      'ble_address': bleAddress,
      'fingerprint': fingerprint,
    });
    return Allocation(
      serial: (body['serial'] as num).toInt(),
      tagHex: (body['tag'] as String).toUpperCase(),
      version: (body['version'] as num?)?.toInt() ?? kSchemeVersion,
      model: model,
    );
  }

  /// Look a serial up. Null when the database has never heard of it — which is
  /// a normal answer here, not an error: it is exactly the branch that asks
  /// the operator whether to wipe and reprogram.
  Future<DeviceRecord?> lookup(int serial) async {
    final res = await _send(() =>
        _client.get(Uri.parse('$baseUrl/admin/devices/$serial'), headers: _headers));
    if (res.statusCode == 404) return null;
    return DeviceRecord.fromJson(_decode(res));
  }

  /// Record a unit whose identity has been written AND read back.
  Future<void> confirm({
    required int serial,
    required DeviceModel model,
    required String tagHex,
    String? bleAddress,
    bool? healthy,
  }) =>
      _post('/admin/devices/confirm', {
        'serial': serial,
        'model': model.wire,
        'tag': tagHex,
        'ble_address': bleAddress,
        'healthy': healthy,
      });

  /// Retire an allocated serial that never made it onto a device, or made it
  /// on badly. The serial is not recycled — see sql/012_devices.sql.
  Future<void> fail({required int serial, String? reason}) =>
      _post('/admin/devices/fail', {'serial': serial, 'reason': reason});

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final res = await _send(() => _client.post(
          Uri.parse('$baseUrl$path'),
          headers: _headers,
          body: jsonEncode(body),
        ));
    return _decode(res);
  }

  Future<http.Response> _send(Future<http.Response> Function() op) async {
    if (!configured) {
      throw const BenchApiException(
        'No server URL or admin token configured. Open Settings.',
      );
    }
    try {
      return await op().timeout(_timeout);
    } on Object catch (e) {
      throw BenchApiException('Cannot reach the server: $e', offline: true);
    }
  }

  Map<String, dynamic> _decode(http.Response res) {
    Map<String, dynamic>? body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      body = null;
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return body ?? const {};
    }
    // The Worker's error strings are terse machine tokens; turning them into
    // sentences here rather than in the UI keeps every caller's failure path
    // to one line, and means a token nobody anticipated still shows up
    // verbatim instead of being swallowed.
    final code = body?['error'] as String? ?? 'http_${res.statusCode}';
    throw BenchApiException(_explain(code), status: res.statusCode);
  }

  static String _explain(String code) => switch (code) {
        'not_configured' =>
          'The server is missing its bench token or signing key.',
        'unauthorized' => 'The admin token was rejected.',
        'model_not_programmable' =>
          'This model has no writable storage and cannot be programmed.',
        'tag_mismatch' =>
          'The server did not mint that tag. Nothing was recorded.',
        'already_programmed' =>
          'That serial is already recorded as programmed.',
        'unknown_serial' => 'The server has no record of that serial.',
        'rate_limited' => 'Too many requests. Wait a moment.',
        _ => code,
      };

  void close() => _client.close();
}

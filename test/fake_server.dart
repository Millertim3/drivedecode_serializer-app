// test/fake_server.dart
//
// The Worker's /admin/devices/* endpoints, in memory.
//
// It mints tags the way src/devices.ts does — HMAC-SHA256 over the same
// domain-separated message, truncated to 11 bytes — so a flow test exercises a
// real tag rather than a placeholder, and the serial/tag pair that reaches the
// fake adapter is the shape a real one would be.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:millerobd_serializer/identity/identity.dart';

class FakeServer {
  /// Serials the database already knows, and the state each is in.
  final Map<int, String> known = {};

  final List<Map<String, dynamic>> allocations = [];
  final List<int> confirmations = [];
  final List<int> failures = [];

  /// Every request fails to connect, as if the bench had no network.
  bool offline = false;

  /// Allocation works; confirming does not. The one window where a network
  /// failure costs something real.
  bool failConfirm = false;

  int _next = 1001;

  /// The development signing key, matching dtc-lookup/test/devices.test.ts.
  static final _key = Uint8List.fromList([
    for (final h in RegExp('..').allMatches(
        'e0f9cd7f4e0605f7f620246f16d107a409b98db33e023d4d28ae067846141b7f'))
      int.parse(h.group(0)!, radix: 16),
  ]);

  static String mintTag(String model, int serial, {int version = 1}) {
    final prefix = ascii.encode('MILLEROBD|${model.toUpperCase()}|');
    final msg = Uint8List(prefix.length + 5);
    msg.setRange(0, prefix.length, prefix);
    msg[prefix.length] = version;
    ByteData.view(msg.buffer).setUint32(prefix.length + 1, serial, Endian.big);
    final digest = Hmac(sha256, _key).convert(msg).bytes;
    return IdentityReader.hex(Uint8List.fromList(digest.sublist(0, kTagLength)));
  }

  Future<http.Response> handle(http.Request req) async {
    if (offline) throw http.ClientException('no route to host');

    final path = req.url.path;
    final body = req.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(req.body) as Map<String, dynamic>;

    if (req.method == 'GET') {
      final serial = int.parse(path.split('/').last);
      final state = known[serial];
      if (state == null) {
        return http.Response(jsonEncode({'found': false}), 404,
            headers: {'content-type': 'application/json'});
      }
      return _json({
        'found': true,
        'serial': serial,
        'model': 'm1',
        'state': state,
        'tag': mintTag('m1', serial),
        'allocated_at': '2026-08-22T18:50:56Z',
        'programmed_at': '2026-08-22T18:50:56Z',
        'healthy': true,
      });
    }

    switch (path) {
      case '/admin/devices/allocate':
        if (body['model'] == 'go') {
          return _json({'error': 'model_not_programmable'}, 409);
        }
        final serial = _next++;
        allocations.add(body);
        known[serial] = 'allocated';
        return _json({
          'serial': serial,
          'tag': mintTag(body['model'] as String, serial),
          'version': kSchemeVersion,
          'model': body['model'],
        });

      case '/admin/devices/confirm':
        if (failConfirm) return _json({'error': 'upstream'}, 502);
        final serial = (body['serial'] as num).toInt();
        confirmations.add(serial);
        known[serial] = 'programmed';
        return _json({'ok': true, 'serial': serial});

      case '/admin/devices/fail':
        final serial = (body['serial'] as num).toInt();
        failures.add(serial);
        known[serial] = 'failed';
        return _json({'ok': true, 'serial': serial});
    }
    return _json({'error': 'not_found'}, 404);
  }

  http.Response _json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );
}

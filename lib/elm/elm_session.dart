// lib/elm/elm_session.dart
//
// The ELM327 line protocol, and nothing else. Write "<command>\r", accumulate
// notify chunks, resolve when the '>' prompt arrives.
//
// ---------------------------------------------------------------------
// WHY THIS IS NOT obd_protocol's ConnectionDriver
//
// drivedecode-app has a perfectly good driver and this deliberately is not it.
// That one exists to talk to a CAR: its init ladder runs ATSP0, probes the
// protocol with 0100, sets an ECU receive filter and negotiates adaptive
// timing. On a bench that is several seconds of waiting per unit for
// information nobody wants — there is no vehicle attached, and the only thing
// being asked of the adapter is that it remember sixteen bytes.
//
// So the setup here is what millerobd_program.py does and no more:
// ATE0 ATL0 ATS0 ATH0. Echo off so responses are not doubled, linefeeds off,
// spaces off, headers off.
//
// ---------------------------------------------------------------------
// STRICT HALF-DUPLEX
//
// These are clone firmwares on an 8-bit micro behind a BLE serial bridge.
// There is one command in flight at a time, always. Overlapping two does not
// pipeline them, it interleaves two replies into one unparseable stream — and
// the failure looks like corrupt data rather than a concurrency bug, which is
// the worst way for it to look. [_chain] is what makes overlap impossible:
// every send queues behind the last, even across callers.

import 'dart:async';
import 'dart:convert';

import '../ble/transport.dart';

/// One command and what came back.
class ElmResponse {
  const ElmResponse(this.command, this.raw);

  final String command;

  /// Everything between the command and the prompt, prompt excluded.
  final String raw;

  /// The response with the echoed command stripped and whitespace collapsed.
  ///
  /// ATE0 is sent at setup, so echo should be off — but the Go answers `OK` to
  /// commands it does not implement and some clones re-enable echo after a
  /// reset, so stripping it defensively costs nothing and prevents a read that
  /// silently returns the command it just sent.
  String get text {
    var t = raw.replaceAll('\r', '\n');
    final lines = t
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && l != '>')
        .where((l) => l.toUpperCase() != command.toUpperCase())
        .toList();
    return lines.join('\n');
  }

  /// True when the adapter rejected the command outright.
  ///
  /// '?' is the ELM327's "I do not understand that", and it is how an M1
  /// refuses a malformed PP write and how a Go refuses every PP write.
  bool get rejected => text.trim() == '?';

  /// True when the adapter answered `OK`.
  ///
  /// USE WITH CARE, AND NEVER AS PROOF. The MillerOBD Go answers a bare `OK`
  /// to commands it has not implemented at all — ATRD, ATCS, ATKW — so an `OK`
  /// from an unknown adapter means "the firmware said something agreeable",
  /// not "the operation happened". The only proof this app accepts that a byte
  /// was stored is reading it back. See BenchController.
  bool get isOk => text.trim().toUpperCase() == 'OK';

  @override
  String toString() => '$command -> ${text.replaceAll("\n", " | ")}';
}

class ElmTimeout implements Exception {
  const ElmTimeout(this.command, this.timeout, this.partial);
  final String command;
  final Duration timeout;
  final String partial;
  @override
  String toString() =>
      'ElmTimeout: "$command" did not answer within '
      '${timeout.inMilliseconds}ms (got: "${partial.trim()}")';
}

/// A queued, prompt-framed conversation with an ELM327 over a [BleTransport].
class ElmSession {
  ElmSession(this._transport) {
    _sub = _transport.incoming.listen(_onBytes);
  }

  final BleTransport _transport;
  late final StreamSubscription<List<int>> _sub;

  /// Command tracing, for the bench log panel. Every line in and out.
  void Function(String)? onTrace;

  /// The serialiser. Each send chains onto the previous one's completion, so
  /// two callers cannot have commands in flight at once.
  Future<void> _chain = Future.value();

  /// The reply being assembled, or null when nothing is outstanding.
  StringBuffer? _buffer;
  Completer<String>? _pending;
  Timer? _deadline;

  /// The default per-command deadline.
  ///
  /// Generous relative to real latencies — the M1 answers most commands in
  /// ~60ms — because the cost of being wrong is asymmetric. A deadline that
  /// fires early during a PP write leaves the app unsure whether the byte
  /// landed, and "unsure" is the one state this tool must never be in about a
  /// unit it is about to ship.
  static const defaultTimeout = Duration(seconds: 5);

  /// ATPPS dumps all 48 slots in one reply. It is the longest response the
  /// bench ever asks for and takes ~240ms on an M1, but it is also the reply
  /// most likely to arrive in many BLE fragments.
  static const ppsTimeout = Duration(seconds: 8);

  bool _closed = false;

  void _onBytes(List<int> bytes) {
    final buffer = _buffer;
    if (buffer == null) return; // unsolicited chatter between commands
    // latin1, not utf8: the ELM speaks 7-bit ASCII, and a stray high byte from
    // a garbled BLE fragment would make a utf8 decoder throw in the middle of
    // an otherwise recoverable reply.
    buffer.write(latin1.decode(bytes, allowInvalid: true));
    if (!buffer.toString().contains('>')) return;

    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    _finish(buffer.toString().replaceAll('>', ''));
  }

  void _finish(String raw) {
    _deadline?.cancel();
    _deadline = null;
    final pending = _pending;
    _pending = null;
    _buffer = null;
    if (pending != null && !pending.isCompleted) pending.complete(raw);
  }

  /// Send one command and wait for its prompt.
  ///
  /// Queued: this returns only after every command sent before it has
  /// finished, including ones from other callers.
  Future<ElmResponse> send(String command, {Duration? timeout}) {
    if (_closed) {
      throw const TransportException(
          FailureReason.bleError, 'ELM session is closed');
    }
    final result = Completer<ElmResponse>();
    _chain = _chain.then((_) async {
      try {
        result.complete(await _sendNow(command, timeout ?? defaultTimeout));
      } on Object catch (e, s) {
        result.completeError(e, s);
      }
    });
    return result.future;
  }

  Future<ElmResponse> _sendNow(String command, Duration timeout) async {
    final buffer = StringBuffer();
    final pending = Completer<String>();
    _buffer = buffer;
    _pending = pending;

    _deadline = Timer(timeout, () {
      if (pending.isCompleted) return;
      final partial = buffer.toString();
      _deadline = null;
      _pending = null;
      _buffer = null;
      pending.completeError(ElmTimeout(command, timeout, partial));
    });

    onTrace?.call('>> $command');
    try {
      // '\r' and not '\n': the ELM327 terminates on carriage return, and a
      // linefeed is read as part of the next command.
      await _transport.write(ascii.encode('$command\r'));
    } on Object {
      _finish(''); // release the slot so the queue does not stall
      rethrow;
    }

    final raw = await pending.future;
    final response = ElmResponse(command, raw);
    onTrace?.call('<< ${response.text.replaceAll("\n", " | ")}');
    return response;
  }

  /// The bench setup sequence: echo, linefeeds, spaces and headers all off.
  ///
  /// Responses are not checked. Every one of these is a display setting, an
  /// adapter that refuses one still stores bytes correctly, and the Go answers
  /// `OK` to things it has not implemented anyway — so a check here would
  /// prove nothing and could reject a working unit. What actually matters is
  /// verified by reading bytes back.
  Future<void> initialize() async {
    for (final cmd in const ['ATE0', 'ATL0', 'ATS0', 'ATH0']) {
      try {
        await send(cmd);
      } on ElmTimeout catch (e) {
        onTrace?.call('setup: $e');
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    _deadline?.cancel();
    _deadline = null;
    final pending = _pending;
    _pending = null;
    _buffer = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const TransportException(
          FailureReason.bleError, 'ELM session closed mid-command'));
    }
    await _sub.cancel();
  }
}

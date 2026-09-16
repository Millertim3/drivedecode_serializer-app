// lib/bench/bench_controller.dart
//
// The flow itself: scan, connect, identify, decide, program, verify, record,
// next.
//
// ---------------------------------------------------------------------
// THE ORDERING RULE THIS FILE EXISTS TO ENFORCE
//
// Every irreversible step happens after the step that could have prevented it,
// and each one is only believed once it has been checked independently:
//
//   1. FINGERPRINT BEFORE WRITE. A Go answers `OK` to commands it has not
//      implemented, so a write to one looks like a success. The model is
//      settled from the GATT layout — before a single command — and a Go stops
//      here.
//
//   2. ALLOCATE BEFORE WRITE, AND ONLY FROM THE SERVER. Two benches computing
//      the next serial independently mint the same number. If allocation
//      fails, nothing has touched the hardware.
//
//   3. READ BACK BEFORE BELIEVING. Neither `OK` nor the absence of `?` is
//      evidence a byte was stored. The bytes coming back changed is.
//
//   4. CONFIRM ONLY AFTER READ-BACK AND HEALTH PASS. The database must never
//      say `programmed` for a unit whose read-back did not match.
//
// ---------------------------------------------------------------------
// WHY THE STATE MACHINE IS EXPLICIT RATHER THAN A SEQUENCE OF AWAITS
//
// Three of the branches need a human: an unknown serial asks before wiping, a
// verify failure asks retry-or-abort, and an enabled-PP fault asks before
// repairing. A straight-line async function cannot pause for that without
// either blocking on a dialog future — which strands the BLE link in an
// undefined state if the window closes — or inverting into callbacks. A state
// the UI renders and an event the UI sends back keeps both halves honest.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/bench_client.dart';
import '../api/registry_journal.dart';
import '../ble/transport.dart';
import '../elm/elm_session.dart';
import '../elm/programmer.dart';
import '../identity/fingerprint.dart';
import '../identity/identity.dart';
import 'bench_state.dart';

/// The adapter name substring both our models advertise.
///
/// A SUBSTRING and not a prefix: the M1 advertises "OBD BLE" and the Go
/// "OBDBLE", and bench units occasionally arrive with a supplier's own name in
/// front. Matching is done in the transport, not pushed to the platform, for
/// exactly this reason.
const String kDeviceNameNeedle = 'OBD';

class BenchController extends ChangeNotifier {
  BenchController({
    required BleTransport Function() transportFactory,
    required BenchClient client,
    RegistryJournal? journal,
  })  : _transportFactory = transportFactory,
        _client = client,
        _journal = journal {
    UniversalTrace.attach(_log);
  }

  /// Builds a transport. A FACTORY and not an instance, because every control
  /// that lets go of the adapter throws the current one away — see
  /// [startScan].
  final BleTransport Function() _transportFactory;

  /// How long the app's own teardown may take before the bench stops waiting
  /// for it. Generous by two orders of magnitude: cancelling subscriptions and
  /// closing a session is microseconds of work, so anything approaching this
  /// is a bug, not slowness.
  static const _localTeardownDeadline = Duration(seconds: 2);

  final BenchClient _client;
  final RegistryJournal? _journal;

  /// The live transport. Null before the first scan, and a DIFFERENT object
  /// after every one.
  BleTransport? _transport;

  /// The current transport, for callers that only run while a link exists.
  BleTransport get _link {
    final t = _transport;
    if (t == null) {
      throw StateError('no transport — startScan has not run');
    }
    return t;
  }

  BenchState _state = const Scanning();
  BenchState get state => _state;

  /// Which unit the bench is working on.
  ///
  /// Bumped by every [startScan], which is every control that lets go of the
  /// adapter. A long operation — connecting, identifying, programming — takes
  /// seconds, and the operator is entitled to give up in the middle of one.
  /// When they do, the operation keeps running to completion anyway: Dart
  /// futures do not cancel, and the awaits inside it are platform calls that
  /// answer when they answer.
  ///
  /// Without this, that abandoned work writes its result over the screen the
  /// operator is now looking at — the scan list flips back to "Identifying" or
  /// to a failure from a unit they already put down, and the button they
  /// pressed looks like it did nothing. Every state write from inside a long
  /// operation is stamped with the flow it belongs to, and a stale one is
  /// dropped.
  ///
  /// The same discipline as the generation bump in drivedecode's
  /// resetTransport, for the same reason: an abandoned attempt must not be
  /// able to emit a success or a failure after the fact.
  int _flow = 0;

  /// The command and BLE log, newest last. Bounded: a bench left running all
  /// day would otherwise grow this without limit, and the useful window is the
  /// last unit or two.
  final List<String> log = [];
  static const _logLimit = 500;

  /// Units successfully programmed since launch. The operator's count.
  int sessionCount = 0;

  StreamSubscription<List<DiscoveredAdapter>>? _scanSub;
  StreamSubscription<bool>? _linkSub;
  ElmSession? _session;
  AdapterProgrammer? _programmer;
  DiscoveredAdapter? _adapter;
  Fingerprint? _fingerprint;

  /// Guards against a second flow starting while one is mid-air — a double
  /// click on Program, or an auto-connect firing into a manual one.
  bool _busy = false;

  void _set(BenchState s) {
    _state = s;
    notifyListeners();
  }

  void _log(String line) {
    log.add(line);
    if (log.length > _logLimit) log.removeRange(0, log.length - _logLimit);
    notifyListeners();
  }

  void clearLog() {
    log.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------

  /// Throw the transport away, build a new one, and scan over that.
  ///
  /// THE BIG HAMMER, AND IT HAS TO BE. A soft disconnect plus a fresh scan can
  /// only recover the state this app owns. It cannot recover the layer
  /// underneath: universal_ble serialises every BLE command through a
  /// process-global queue with no timeout of its own, so one native call that
  /// never answers starves every later command for the LIFE OF THE PROCESS.
  /// That is the state behind drivedecode's field report — "sits on Looking
  /// for your adapter even after pressing rescan; the only way to re-find the
  /// adapter is to close the app" — and rebuilding the transport is what makes
  /// this button mean something in it. On a bench that matters more than it
  /// does in the app: the operator's next move after any outcome, good or bad,
  /// is this button, and a bench that needs restarting between units is a
  /// bench nobody uses.
  ///
  /// Every path that lets go of the adapter comes through here — Next Device,
  /// the header's Disconnect, Abort, and the retry that starts over. One
  /// recovery, so there is no second version to drift.
  ///
  /// THREE ORDERING RULES, all load-bearing:
  ///
  ///   1. Local state goes first, and it is the only thing awaited. Cancelling
  ///      subscriptions and closing the session is pure Dart and cannot block.
  ///
  ///   2. The old transport is retired BEFORE the new scan starts, and is
  ///      NEVER awaited. Not awaiting is the point — a wedged native queue is
  ///      exactly the state this button is pressed in, and awaiting a call
  ///      into it is how the button comes to do nothing visible at all.
  ///
  ///      What protects the new scan from the old transport's dying stopScan
  ///      is NOT this ordering. It cannot be: `UniversalBle.disconnect` keeps
  ///      waiting for a connection event long after its queued command has
  ///      returned, so the old teardown finishes whenever it finishes — often
  ///      seconds after the new scan is already running. The guard is the
  ///      generation check in UniversalBleTransport, which keeps a replaced
  ///      instance away from a radio it no longer owns. See its [_generation].
  ///
  ///   3. No soft `disconnect()` anywhere. [BleTransport.dispose] does that
  ///      and harder — it marks the instance dead first, so a teardown still
  ///      unwinding can never touch the radio the new instance now owns.
  Future<void> startScan({String? error}) async {
    // Anything still in flight from the last unit belongs to a flow the
    // operator has walked away from. It may still finish; it may not write
    // state when it does.
    _flow++;

    // 1. Ours, and bounded. Everything in here is pure Dart and should take
    //    microseconds — but "should" is what this button has been wrong about
    //    twice now, and a teardown step that blocks makes it dead on arrival
    //    rather than merely slow. If it ever exceeds this, the bench moves on
    //    without it and the log says so.
    try {
      await _releaseLocalState().timeout(_localTeardownDeadline);
    } on TimeoutException {
      _log('teardown: local state did not release in '
          '${_localTeardownDeadline.inMilliseconds}ms — continuing anyway');
    }

    // 2. Retire before rebuild, and never await the retirement.
    final outgoing = _transport;
    if (outgoing != null) {
      _log('transport: retiring and rebuilding');
      _retire(outgoing);
    }
    _transport = _transportFactory();

    _set(Scanning(error: error));

    // 3. The scan runs on the new instance.
    _scanSub = _link.scan(deviceName: kDeviceNameNeedle).listen(
      (adapters) {
        // Only while still scanning: a batch arriving after the operator has
        // already connected must not throw the screen back to the picker.
        if (_state is! Scanning) return;
        _set(Scanning(adapters: adapters, error: error));
      },
      onError: (Object e) {
        _set(Scanning(error: '$e'));
      },
    );
  }

  // ---------------------------------------------------------------------
  // Connect and identify
  // ---------------------------------------------------------------------

  /// Connect to [adapter], set it up, work out what it is, and read whatever
  /// identity it already carries.
  Future<void> connect(DiscoveredAdapter adapter) async {
    if (_busy) return;
    _busy = true;
    // Stamp every state write below with the unit this call belongs to, so a
    // Disconnect pressed midway through cannot be undone by work that was
    // already in the air. See [_flow].
    final flow = _flow;
    void set(BenchState next) {
      if (flow != _flow) return;
      _set(next);
    }

    try {
      await _scanSub?.cancel();
      _scanSub = null;
      _adapter = adapter;
      set(Connecting(adapter));

      await _link.connect(adapter.id);
      _watchLink();

      final session = ElmSession(_link)..onTrace = _log;
      _session = session;
      _programmer = AdapterProgrammer(session);

      set(Identifying(adapter, 'Configuring adapter'));
      await session.initialize();

      set(Identifying(adapter, 'Identifying model'));
      final fingerprint =
          await fingerprintAdapter(gatt: _link.gatt, session: session);
      _fingerprint = fingerprint;
      for (final s in fingerprint.signals) {
        _log('fingerprint: $s');
      }

      // Rule 1. Nothing below this point writes, but the decision belongs here
      // where it is unmissable rather than buried in the write path.
      if (fingerprint.model == null) {
        set(NotProgrammable(adapter, fingerprint,
            'This adapter does not expose the MillerOBD vendor service. It is '
            'not one of ours.'));
        return;
      }
      if (!fingerprint.model!.isProgrammable) {
        set(NotProgrammable(adapter, fingerprint,
            'This is a ${fingerprint.model!.label}. It has no writable '
            'storage — PP writes are rejected and ATSD writes are ignored — so '
            'it cannot carry a serial. Its entitlement is keyed on its '
            'Bluetooth identity instead.'));
        return;
      }

      set(Identifying(adapter, 'Reading identity'));
      final read = await _programmer!.readIdentity();

      // Checked before the identity is interpreted: if the slots are enabled,
      // the firmware is acting on them and everything else read is suspect.
      if (read.needsRepair) {
        _log('WARNING: identity slots are ENABLED: '
            '${read.enabledIdentitySlots.join(", ")}');
        set(NeedsRepair(adapter, fingerprint, read));
        return;
      }

      if (read.identity.partial) {
        _log('identity is partially written — serial bytes '
            '${read.identity.displaySerial}, some slots still FF');
        set(PartiallyProgrammed(adapter, fingerprint, read));
        return;
      }

      if (!read.identity.programmed) {
        _log('identity: blank (all slots FF)');
        set(ReadyToProgram(adapter, fingerprint));
        return;
      }

      // Carries a serial. Ask the database whether it is one of ours.
      _log('identity: ${read.identity.displaySerial} '
          'v${read.identity.version} tag ${read.identity.tagHex}');
      set(Identifying(adapter, 'Checking the database'));
      final record = await _client.lookup(read.identity.serial);
      if (record != null) {
        set(AlreadyProgrammed(adapter, fingerprint, read, record));
      } else {
        set(UnknownSerial(adapter, fingerprint, read));
      }
    } on Object catch (e) {
      _fail('Could not identify the adapter', '$e',
          canRetry: true, flow: flow);
    } finally {
      _busy = false;
    }
  }

  // ---------------------------------------------------------------------
  // Program
  // ---------------------------------------------------------------------

  /// Allocate a serial, write it, read it back, health-check, record.
  ///
  /// [wipeFirst] erases the existing identity before writing. Reached only
  /// from [UnknownSerial] and [PartiallyProgrammed], and only on an explicit
  /// operator confirmation — the app never wipes an identity on its own.
  Future<void> program({bool wipeFirst = false}) async {
    final adapter = _adapter;
    final programmer = _programmer;
    final fingerprint = _fingerprint;
    if (adapter == null || programmer == null || fingerprint == null) return;
    if (_busy) return;
    _busy = true;
    // Stamp every state write below with the unit this call belongs to, so a
    // Disconnect pressed midway through cannot be undone by work that was
    // already in the air. See [_flow].
    final flow = _flow;
    void set(BenchState next) {
      if (flow != _flow) return;
      _set(next);
    }

    Allocation? allocation;
    try {
      // Rule 2: the serial comes from the server, and it comes BEFORE any
      // write. An offline bench stops here, having touched nothing.
      set(Allocating(adapter));
      allocation = await _client.allocate(
        model: fingerprint.model!,
        bleAddress: adapter.id,
        fingerprint: fingerprint.toJson(),
      );
      _log('allocated ${allocation.displaySerial} '
          '(tag ${allocation.tagHex})');

      if (wipeFirst) {
        set(Writing(adapter, allocation, 'Erasing the existing identity'));
        final erased = await programmer.eraseIdentity();
        if (!erased.ok) {
          _failAllocated(allocation, adapter, 'Erase did not complete',
              erased.describeMismatches(), flow: flow);
          return;
        }
      }

      set(Writing(adapter, allocation, 'Writing identity'));
      // Rule 3: writeIdentity reads every byte back and compares against what
      // we intended. Its `ok` is the only success signal this flow accepts.
      final result = await programmer.writeIdentity(
        serial: allocation.serial,
        tagHex: allocation.tagHex,
        version: allocation.version,
      );
      if (!result.ok) {
        _failAllocated(
          allocation,
          adapter,
          'Read-back did not match what was written',
          '${result.describeMismatches()}\n\n'
              'If this adapter is a Go this is expected — it has no writable '
              'storage. Otherwise the write was interrupted; the slots are '
              'rewritable, so retrying is safe.',
          flow: flow,
        );
        return;
      }
      _log('read-back matched on all ${kAllSlots.length} slots + user byte');

      set(Writing(adapter, allocation, 'Checking adapter health'));
      final health = await programmer.healthCheck();
      _log('health: ATI="${health.version}" ATDPN="${health.protocol}" '
          'ATRV="${health.voltage}"');
      if (!health.ok) {
        _failAllocated(
          allocation,
          adapter,
          'The adapter stopped answering normally after programming',
          'ATI="${health.version}" ATDPN="${health.protocol}". A unit that '
              'fails this must not ship even though its identity is valid.',
          flow: flow,
        );
        return;
      }

      // Rule 4. Everything above passed, so the unit is real; from here on the
      // only thing that can go wrong is the network, and that is recoverable.
      set(Writing(adapter, allocation, 'Recording'));
      final recorded = await _record(allocation, adapter, health);

      sessionCount++;
      set(Success(
        adapter: adapter,
        allocation: allocation,
        health: health,
        recorded: recorded,
        sessionCount: sessionCount,
      ));
    } on BenchApiException catch (e) {
      // An allocation that never returned burned nothing. One that did leaves
      // a row to retire, which _failAllocated handles.
      if (allocation == null) {
        _fail(e.offline ? 'The bench is offline' : 'The server refused',
            '${e.message}\n\nNothing was written to the adapter.',
            canRetry: true, flow: flow);
      } else {
        _failAllocated(allocation, adapter, 'The server refused', e.message,
            flow: flow);
      }
    } on Object catch (e) {
      if (allocation == null) {
        _fail('Programming failed', '$e', canRetry: true, flow: flow);
      } else {
        _failAllocated(allocation, adapter, 'Programming failed', '$e',
            flow: flow);
      }
    } finally {
      _busy = false;
    }
  }

  /// Tell the server, and journal the result either way.
  ///
  /// The journal entry is written whether or not /confirm succeeded, because
  /// by this point the bytes ARE on the device. A confirm that fails leaves an
  /// unconfirmed entry, which [retryPendingConfirmations] picks up on the next
  /// launch — the alternative is a unit in the field whose serial the
  /// entitlement server has never heard of.
  Future<bool> _record(
    Allocation allocation,
    DiscoveredAdapter adapter,
    HealthCheck health,
  ) async {
    var recorded = false;
    try {
      await _client.confirm(
        serial: allocation.serial,
        model: allocation.model,
        tagHex: allocation.tagHex,
        bleAddress: adapter.id,
        healthy: health.ok,
      );
      recorded = true;
    } on Object catch (e) {
      _log('WARNING: could not record ${allocation.displaySerial}: $e '
          '— queued for retry');
    }
    try {
      await _journal?.append(JournalEntry(
        serial: allocation.serial,
        model: allocation.model,
        tagHex: allocation.tagHex,
        version: allocation.version,
        bleAddress: adapter.id,
        programmedAt: DateTime.now(),
        healthy: health.ok,
        confirmed: recorded,
      ));
    } on Object catch (e) {
      _log('WARNING: could not write the local journal: $e');
    }
    return recorded;
  }

  /// Re-send confirmations for units programmed while the bench was offline.
  /// Called at launch; failures are logged and left queued.
  Future<void> retryPendingConfirmations() async {
    final journal = _journal;
    if (journal == null || !_client.configured) return;
    final pending = await journal.pendingConfirmations();
    if (pending.isEmpty) return;
    _log('retrying ${pending.length} unrecorded unit(s) from the journal');
    for (final entry in pending) {
      try {
        await _client.confirm(
          serial: entry.serial,
          model: entry.model,
          tagHex: entry.tagHex,
          bleAddress: entry.bleAddress,
          healthy: entry.healthy,
        );
        await journal.append(JournalEntry(
          serial: entry.serial,
          model: entry.model,
          tagHex: entry.tagHex,
          version: entry.version,
          bleAddress: entry.bleAddress,
          programmedAt: entry.programmedAt,
          healthy: entry.healthy,
          confirmed: true,
        ));
        _log('recorded ${formatSerial(entry.serial)} (was queued)');
      } on Object catch (e) {
        _log('still cannot record ${formatSerial(entry.serial)}: $e');
      }
    }
  }

  /// Turn every programmable parameter back off, then re-identify.
  Future<void> repair() async {
    final programmer = _programmer;
    final adapter = _adapter;
    if (programmer == null || adapter == null) return;
    try {
      _set(Identifying(adapter, 'Disabling all parameters'));
      await programmer.disableAllParameters();
      _log('sent ATPP FF OFF');
      // Re-read rather than assume: the whole reason we are here is that the
      // adapter was in a state nobody expected.
      final read = await programmer.readIdentity();
      if (read.needsRepair) {
        _set(NeedsRepair(adapter, _fingerprint!, read));
        return;
      }
      if (read.identity.programmed && !read.identity.partial) {
        final record = await _client.lookup(read.identity.serial);
        _set(record != null
            ? AlreadyProgrammed(adapter, _fingerprint!, read, record)
            : UnknownSerial(adapter, _fingerprint!, read));
      } else if (read.identity.partial) {
        _set(PartiallyProgrammed(adapter, _fingerprint!, read));
      } else {
        _set(ReadyToProgram(adapter, _fingerprint!));
      }
    } on Object catch (e) {
      _fail('Repair failed', '$e', canRetry: true);
    }
  }

  // ---------------------------------------------------------------------
  // Failure and teardown
  // ---------------------------------------------------------------------

  /// [flow] is the unit the caller was working on — see [_flow]. Omitted only
  /// by the link watcher, whose events are about the present moment rather
  /// than about a unit.
  void _fail(String message, String detail,
      {required bool canRetry, int? flow}) {
    if (flow != null && flow != _flow) return;
    _log('FAILED: $message — $detail');
    _set(Failed(
      message: message,
      detail: detail,
      canRetry: canRetry,
      adapter: _adapter,
    ));
  }

  void _failAllocated(
    Allocation allocation,
    DiscoveredAdapter adapter,
    String message,
    String detail, {
    int? flow,
  }) {
    if (flow != null && flow != _flow) return;
    _log('FAILED at ${allocation.displaySerial}: $message — $detail');
    _set(Failed(
      message: message,
      detail: detail,
      canRetry: true,
      adapter: adapter,
      allocation: allocation,
    ));
  }

  /// Try the same allocated serial again.
  ///
  /// Reuses the allocation rather than taking a new one. The serial may
  /// already be partly written into EEPROM, and issuing a second number would
  /// leave the first stranded in the database against a device that no longer
  /// carries it.
  Future<void> retry() async {
    final failed = _state;
    if (failed is! Failed) return;
    final allocation = failed.allocation;
    final programmer = _programmer;
    final adapter = failed.adapter;

    if (allocation == null || programmer == null || adapter == null) {
      // Nothing was allocated — this failed before the server was involved, so
      // the honest retry is the whole flow from the top.
      await startScan();
      return;
    }

    _busy = true;
    try {
      _set(Writing(adapter, allocation, 'Rewriting identity'));
      final result = await programmer.writeIdentity(
        serial: allocation.serial,
        tagHex: allocation.tagHex,
        version: allocation.version,
      );
      if (!result.ok) {
        _failAllocated(allocation, adapter, 'Read-back still does not match',
            result.describeMismatches());
        return;
      }
      final health = await programmer.healthCheck();
      final recorded = await _record(allocation, adapter, health);
      sessionCount++;
      _set(Success(
        adapter: adapter,
        allocation: allocation,
        health: health,
        recorded: recorded,
        sessionCount: sessionCount,
      ));
    } on Object catch (e) {
      _failAllocated(allocation, adapter, 'Retry failed', '$e');
    } finally {
      _busy = false;
    }
  }

  /// Give up on this unit, retire its serial if one was issued, and go back to
  /// scanning.
  Future<void> abort() async {
    final failed = _state;
    final allocation = failed is Failed ? failed.allocation : null;
    if (allocation != null) {
      try {
        await _client.fail(
          serial: allocation.serial,
          reason: failed is Failed ? failed.message : 'aborted at the bench',
        );
        _log('retired ${allocation.displaySerial}');
      } on Object catch (e) {
        // The serial stays 'allocated' server-side, which is visible and
        // fixable. Blocking the operator on it would be worse.
        _log('could not retire ${allocation.displaySerial}: $e');
      }
    }
    await startScan(error: failed is Failed ? failed.message : null);
  }

  /// Disconnect and go straight back to scanning. The one-click-per-unit
  /// control on the success screen, and the manual escape everywhere else.
  Future<void> nextDevice() => startScan();

  /// Drop everything built on top of the transport.
  ///
  /// Deliberately does NOT call `transport.disconnect()`. That used to be here
  /// and it read like the careful version, which is the opposite of what it
  /// was: [_retire] disposes the instance, and dispose already awaits its own
  /// disconnect before it stops the radio. The soft call added nothing, and it
  /// was the one step in this teardown that could block — a call into the very
  /// native queue whose wedging is the reason the button was pressed.
  ///
  /// Everything left here is pure Dart: cancelling subscriptions and closing a
  /// session that owns nothing but a stream listener.
  Future<void> _releaseLocalState() async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _linkSub?.cancel();
    _linkSub = null;
    await _session?.close();
    _session = null;
    _programmer = null;
    _adapter = null;
    _fingerprint = null;
  }

  /// Send a transport to its death without waiting for it.
  ///
  /// Fire-and-forget on purpose — see rule 2 on [startScan]. The instance
  /// marks itself dead synchronously inside dispose(), which is the part that
  /// matters for correctness; everything after that is cleanup that may take
  /// as long as it likes, or never finish, without anyone depending on it.
  ///
  /// Failures are logged rather than thrown. A transport being torn down
  /// because something already went wrong is entitled to fail on the way out,
  /// and there is no caller left to tell.
  void _retire(BleTransport outgoing) {
    unawaited(
      outgoing.dispose().catchError((Object e) {
        _log('transport: teardown failed on the way out — $e');
      }),
    );
  }

  /// Notice a link that drops underneath us.
  ///
  /// `skipWhile` on the replayed current value: the transport replays the
  /// present state to each new listener, so without this guard the `true` we
  /// just established would be followed by nothing and a later real `false`
  /// would be the first thing seen — or, worse with a different guard, skipped.
  void _watchLink() {
    _linkSub?.cancel();
    _linkSub = _link.connectionState
        .skipWhile((connected) => !connected)
        .listen((connected) {
      if (connected) return;
      _log('link dropped');
      // A dropped link mid-write is exactly the partial-write case, and the
      // next identify will find it and say so.
      if (_state is Success || _state is Scanning) return;
      _fail('The adapter disconnected',
          'The link dropped before this unit finished. Power-cycle it and '
              'connect again — a partial write is recoverable.',
          canRetry: false);
    });
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _linkSub?.cancel();
    _session?.close();
    _transport?.dispose();
    _client.close();
    super.dispose();
  }
}

/// Bridges the transport's static trace hook onto an instance's log.
///
/// Static because [UniversalBleTransport.onTrace] is — it has to be, since
/// nothing above the transport can see a BleService. Kept in one place so
/// there is a single answer to "who owns the trace hook" rather than an
/// assignment buried in a constructor.
abstract final class UniversalTrace {
  static void Function(String)? _sink;

  static void attach(void Function(String) sink) => _sink = sink;

  static void emit(String line) => _sink?.call(line);
}

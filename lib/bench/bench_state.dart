// lib/bench/bench_state.dart
//
// Every state the bench can be in, as a sealed hierarchy.
//
// SEALED, AND THE EXHAUSTIVENESS IS THE POINT. The UI switches over this with
// no default arm, so adding a state here fails compilation until someone has
// decided what an operator sees when the bench is in it. That property is
// worth more on a tool that decides whether hardware ships than it is in a
// consumer app: an unhandled state on this screen is a blank panel in front of
// someone holding a device they are about to put in a box.
//
// The flow, in the order an operator lives it:
//
//   Scanning -> Connecting -> Identifying -> ...
//
//     ...NotProgrammable          (a Go — dead end, with the reason)
//     ...Blank                    -> Allocating -> Writing -> Verifying
//     ...AlreadyProgrammed        (known serial — dead end, informational)
//     ...UnknownSerial            (confirm wipe) -> Allocating -> ...
//     ...NeedsRepair              (PPs enabled by another app) -> repair
//
//   Verifying -> Success | Failed(retry | abort)

import '../api/bench_client.dart';
import '../ble/transport.dart';
import '../elm/programmer.dart';
import '../identity/fingerprint.dart';

sealed class BenchState {
  const BenchState();
}

/// Looking for an adapter. The resting state, and where every unit starts and
/// finishes.
class Scanning extends BenchState {
  const Scanning({this.adapters = const [], this.error});
  final List<DiscoveredAdapter> adapters;

  /// A scan that could not start, or the failure that ended the last unit.
  /// Carried here rather than cleared so an operator who looks away does not
  /// lose the reason.
  final String? error;
}

class Connecting extends BenchState {
  const Connecting(this.adapter);
  final DiscoveredAdapter adapter;
}

/// Connected; running the setup sequence, fingerprinting, and reading whatever
/// identity is already on the device.
class Identifying extends BenchState {
  const Identifying(this.adapter, this.step);
  final DiscoveredAdapter adapter;
  final String step;
}

/// The adapter is a model with no writable storage.
///
/// A dead end on purpose. The Go answers `OK` to commands it has not
/// implemented, so writing to one would look like it worked; refusing here is
/// the difference between an explanation and a mystery failure.
class NotProgrammable extends BenchState {
  const NotProgrammable(this.adapter, this.fingerprint, this.reason);
  final DiscoveredAdapter adapter;
  final Fingerprint fingerprint;
  final String reason;
}

/// Some identity slots are set and some are still FF.
///
/// Neither blank nor programmed: the signature of a write that lost BLE
/// halfway. Recoverable — the slots are freely rewritable — but it must be
/// recognised, because treating it as blank would issue a second serial over
/// the remains of a first.
class PartiallyProgrammed extends BenchState {
  const PartiallyProgrammed(this.adapter, this.fingerprint, this.read);
  final DiscoveredAdapter adapter;
  final Fingerprint fingerprint;
  final IdentityRead read;
}

/// The identity slots are enabled, which they must never be.
///
/// Something issued `AT PP FF ON` — a third-party OBD app doing a factory
/// reset the thorough way. The firmware is now acting on bytes that are an
/// HMAC. One command puts it back, and the operator is offered it.
class NeedsRepair extends BenchState {
  const NeedsRepair(this.adapter, this.fingerprint, this.read);
  final DiscoveredAdapter adapter;
  final Fingerprint fingerprint;
  final IdentityRead read;
}

/// Blank and programmable. Ready to go.
class ReadyToProgram extends BenchState {
  const ReadyToProgram(this.adapter, this.fingerprint);
  final DiscoveredAdapter adapter;
  final Fingerprint fingerprint;
}

/// The adapter carries a serial the database already knows.
///
/// Informational and terminal: this unit has been done. The record is shown so
/// an operator can see when, and whether it passed its health check.
class AlreadyProgrammed extends BenchState {
  const AlreadyProgrammed(this.adapter, this.fingerprint, this.read, this.record);
  final DiscoveredAdapter adapter;
  final Fingerprint fingerprint;
  final IdentityRead read;
  final DeviceRecord record;
}

/// The adapter carries a serial, and the database has never heard of it.
///
/// Either a unit programmed by the old Python tool whose registry was never
/// uploaded, or something that is not ours. The operator decides; the app does
/// not wipe an identity on its own initiative.
class UnknownSerial extends BenchState {
  const UnknownSerial(this.adapter, this.fingerprint, this.read);
  final DiscoveredAdapter adapter;
  final Fingerprint fingerprint;
  final IdentityRead read;
}

/// Asking the server for a serial. Distinct from [Writing] because it is the
/// step that fails when the bench is offline, and nothing has touched the
/// hardware yet.
class Allocating extends BenchState {
  const Allocating(this.adapter);
  final DiscoveredAdapter adapter;
}

class Writing extends BenchState {
  const Writing(this.adapter, this.allocation, this.step);
  final DiscoveredAdapter adapter;
  final Allocation allocation;
  final String step;
}

/// Programmed, verified, recorded.
class Success extends BenchState {
  const Success({
    required this.adapter,
    required this.allocation,
    required this.health,
    required this.recorded,
    required this.sessionCount,
  });

  final DiscoveredAdapter adapter;
  final Allocation allocation;
  final HealthCheck health;

  /// Whether the server acknowledged it. False means the bytes are on the
  /// device and the record is queued in the local journal for retry — a real
  /// distinction, and one the operator should see rather than discover later.
  final bool recorded;

  final int sessionCount;
}

/// Something went wrong at a step that can be tried again.
class Failed extends BenchState {
  const Failed({
    required this.message,
    required this.detail,
    required this.canRetry,
    this.adapter,
    this.allocation,
  });

  final String message;

  /// The specific evidence — mismatched slots, the transport error, the
  /// server's refusal. Shown below the headline, because "verify failed" is
  /// not enough to act on and "PP 1D: wanted C7, read FF" is.
  final String detail;

  final bool canRetry;
  final DiscoveredAdapter? adapter;

  /// The serial already allocated to this attempt, if any. Retrying reuses it
  /// rather than burning another; aborting retires it.
  final Allocation? allocation;
}

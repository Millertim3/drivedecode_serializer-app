// lib/ui/bench_screen.dart
//
// The single window. One exhaustive switch over BenchState — no default arm,
// so a state added to the sealed hierarchy fails compilation here until
// someone has decided what the operator sees.
//
// ---------------------------------------------------------------------
// THE ONE-BUTTON RULE
//
// A hundred-unit run is a hundred repetitions of the same gesture, and the
// operator is holding a device in the other hand. So there is exactly one
// primary button, in the same place on every panel, and only its label
// changes: Program, Retry, Next Device. Everything else — abort, disconnect,
// settings — is secondary and visually quieter.

import 'package:flutter/material.dart';

import '../bench/bench_controller.dart';
import '../bench/bench_state.dart';
import '../elm/programmer.dart';
import '../identity/fingerprint.dart';
import 'log_panel.dart';
import 'settings_dialog.dart';
import 'theme.dart';

class BenchScreen extends StatelessWidget {
  const BenchScreen({super.key, required this.controller});

  final BenchController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final state = controller.state;
        return Scaffold(
          body: Column(
            children: [
              _Header(controller: controller, state: state),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 32, vertical: 24),
                      // The exhaustive switch. No default arm, on purpose.
                      child: switch (state) {
                        Scanning() => _ScanPanel(
                            state: state, controller: controller),
                        Connecting() => _Busy(
                            title: 'Connecting to ${state.adapter.name}',
                            detail: state.adapter.id),
                        Identifying() => _Busy(
                            title: state.step, detail: state.adapter.name),
                        NotProgrammable() =>
                          _NotProgrammablePanel(state: state, controller: controller),
                        NeedsRepair() =>
                          _RepairPanel(state: state, controller: controller),
                        PartiallyProgrammed() =>
                          _PartialPanel(state: state, controller: controller),
                        ReadyToProgram() =>
                          _ReadyPanel(state: state, controller: controller),
                        AlreadyProgrammed() =>
                          _AlreadyPanel(state: state, controller: controller),
                        UnknownSerial() =>
                          _UnknownPanel(state: state, controller: controller),
                        Allocating() => const _Busy(
                            title: 'Allocating a serial',
                            detail: 'Asking the server for the next number'),
                        Writing() => _Busy(
                            title: state.step,
                            detail: state.allocation.displaySerial),
                        Success() =>
                          _SuccessPanel(state: state, controller: controller),
                        Failed() =>
                          _FailedPanel(state: state, controller: controller),
                      },
                    ),
                  ),
                ),
              ),
              LogPanel(lines: controller.log, onClear: controller.clearLog),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.state});
  final BenchController controller;
  final BenchState state;

  @override
  Widget build(BuildContext context) {
    final connected = state is! Scanning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        border: Border(bottom: BorderSide(color: Color(0xFF30363D))),
      ),
      child: Row(
        children: [
          const Icon(Icons.memory, size: 20),
          const SizedBox(width: 10),
          const Text('MillerOBD Serializer',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(width: 16),
          _Pill(
            label: connected ? 'Connected' : 'Scanning',
            color: connected ? kGood : const Color(0xFF8B949E),
          ),
          const Spacer(),
          Text('${controller.sessionCount} programmed this session',
              style: const TextStyle(color: Color(0xFF8B949E), fontSize: 13)),
          const SizedBox(width: 12),
          // Always available, for the "or something else" case: an operator
          // who needs the radio released without finishing a unit.
          if (connected)
            TextButton.icon(
              onPressed: controller.nextDevice,
              icon: const Icon(Icons.link_off, size: 18),
              label: const Text('Disconnect'),
            ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => showBenchSettings(context),
            icon: const Icon(Icons.settings, size: 20),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}

// ---------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------

class _Panel extends StatelessWidget {
  const _Panel({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    this.primary,
    this.secondary,
  });

  final IconData icon;
  final Color color;
  final String title;
  final List<Widget> body;
  final Widget? primary;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 20),
          ...body,
          if (primary != null || secondary != null) ...[
            const SizedBox(height: 28),
            Row(children: [
              if (primary != null) primary!,
              if (primary != null && secondary != null) const SizedBox(width: 12),
              if (secondary != null) secondary!,
            ]),
          ],
        ],
      );
}

class _Busy extends StatelessWidget {
  const _Busy({required this.title, required this.detail});
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 40),
          const SizedBox(
              width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(height: 24),
          Text(title, style: const TextStyle(fontSize: 18)),
          const SizedBox(height: 6),
          Text(detail,
              style: kMono.copyWith(fontSize: 13, color: const Color(0xFF8B949E))),
        ],
      );
}

/// A label/value row. Values are monospaced because most of them are hex.
class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 140,
              child: Text(label,
                  style: const TextStyle(color: Color(0xFF8B949E), fontSize: 13)),
            ),
            Expanded(
              child: SelectableText(value,
                  style: kMono.copyWith(fontSize: 13, color: color)),
            ),
          ],
        ),
      );
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.color = kWarn, this.icon = Icons.info_outline});
  final String text;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 4, bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text, style: const TextStyle(fontSize: 13, height: 1.5))),
        ]),
      );
}

Widget _fingerprintCard(Fingerprint f) => Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(f.model?.label ?? 'Unrecognised adapter',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 10),
            if (f.model != null && !f.confident)
              const _Pill(label: 'low confidence', color: kWarn),
          ]),
          const SizedBox(height: 10),
          for (final s in f.signals)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('· $s',
                  style: kMono.copyWith(
                      fontSize: 12, color: const Color(0xFF8B949E))),
            ),
        ]),
      ),
    );

// ---------------------------------------------------------------------
// Panels
// ---------------------------------------------------------------------

class _ScanPanel extends StatelessWidget {
  const _ScanPanel({required this.state, required this.controller});
  final Scanning state;
  final BenchController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Row(children: [
          const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 14),
          Text(
            state.adapters.isEmpty
                ? 'Looking for an adapter — power one up'
                : 'Found ${state.adapters.length}',
            style: const TextStyle(fontSize: 18),
          ),
        ]),
        const SizedBox(height: 20),
        if (state.error != null) _Note(state.error!, color: kBad),
        if (state.adapters.isEmpty)
          const _Note(
            'Plug the adapter into the bench harness or a vehicle port and '
            'wait for its light. Adapters advertise a few seconds after '
            'power-up.',
            icon: Icons.bolt,
          ),
        for (final a in state.adapters)
          Card(
            child: ListTile(
              leading: const Icon(Icons.bluetooth, color: kBrand),
              title: Text(a.name),
              subtitle: Text(a.id, style: kMono.copyWith(fontSize: 12)),
              trailing: Text('${a.rssi} dBm',
                  style: kMono.copyWith(
                      fontSize: 12, color: const Color(0xFF8B949E))),
              onTap: () => controller.connect(a),
            ),
          ),
      ],
    );
  }
}

class _NotProgrammablePanel extends StatelessWidget {
  const _NotProgrammablePanel({required this.state, required this.controller});
  final NotProgrammable state;
  final BenchController controller;

  @override
  Widget build(BuildContext context) => _Panel(
        icon: Icons.block,
        color: kWarn,
        title: 'This adapter cannot be programmed',
        body: [
          _Note(state.reason, color: kWarn),
          _fingerprintCard(state.fingerprint),
        ],
        primary: FilledButton(
            onPressed: controller.nextDevice, child: const Text('Next Device')),
      );
}

class _RepairPanel extends StatelessWidget {
  const _RepairPanel({required this.state, required this.controller});
  final NeedsRepair state;
  final BenchController controller;

  @override
  Widget build(BuildContext context) => _Panel(
        icon: Icons.build,
        color: kWarn,
        title: 'Identity parameters are enabled',
        body: [
          const _Note(
            'Something has issued AT PP FF ON to this adapter — a third-party '
            'app doing a thorough factory reset. The firmware is now acting on '
            'bytes that are meant to be inert storage. One command puts it '
            'back.',
            color: kWarn,
          ),
          _Field('Enabled slots', state.enabled),
        ],
        primary: FilledButton(
            onPressed: controller.repair,
            child: const Text('Disable parameters')),
        secondary: OutlinedButton(
            onPressed: controller.nextDevice, child: const Text('Skip')),
      );
}

extension on NeedsRepair {
  String get enabled => read.enabledIdentitySlots.join(', ');
}

class _PartialPanel extends StatelessWidget {
  const _PartialPanel({required this.state, required this.controller});
  final PartiallyProgrammed state;
  final BenchController controller;

  @override
  Widget build(BuildContext context) => _Panel(
        icon: Icons.warning_amber,
        color: kWarn,
        title: 'Half-written identity',
        body: [
          const _Note(
            'Some identity slots are set and some are still FF — the signature '
            'of a write that lost its connection. The slots are freely '
            'rewritable, so this is recoverable: erase and program with a '
            'fresh serial.',
            color: kWarn,
          ),
          _Field('Serial bytes read', state.read.identity.displaySerial),
          _Field('Scheme version',
              '0x${state.read.identity.version.toRadixString(16).toUpperCase()}'),
          _fingerprintCard(state.fingerprint),
        ],
        primary: FilledButton(
            onPressed: () => controller.program(wipeFirst: true),
            child: const Text('Erase and program')),
        secondary: OutlinedButton(
            onPressed: controller.nextDevice, child: const Text('Skip')),
      );
}

class _ReadyPanel extends StatelessWidget {
  const _ReadyPanel({required this.state, required this.controller});
  final ReadyToProgram state;
  final BenchController controller;

  @override
  Widget build(BuildContext context) => _Panel(
        icon: Icons.check_circle_outline,
        color: kBrand,
        title: 'Blank adapter — ready to program',
        body: [
          const _Note(
            'All identity slots read FF. A serial will be allocated by the '
            'server, written, and read back before anything is recorded.',
            color: kBrand,
            icon: Icons.info_outline,
          ),
          _fingerprintCard(state.fingerprint),
        ],
        primary: FilledButton(
            onPressed: () => controller.program(), child: const Text('Program')),
        secondary: OutlinedButton(
            onPressed: controller.nextDevice, child: const Text('Skip')),
      );
}

class _AlreadyPanel extends StatelessWidget {
  const _AlreadyPanel({required this.state, required this.controller});
  final AlreadyProgrammed state;
  final BenchController controller;

  @override
  Widget build(BuildContext context) {
    final r = state.record;
    return _Panel(
      icon: Icons.verified,
      color: kGood,
      title: 'Already programmed',
      body: [
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: SelectableText(
              r.displaySerial,
              style: kMono.copyWith(
                  fontSize: 34, fontWeight: FontWeight.w600, color: kGood),
            ),
          ),
        ),
        _Field('Tag', state.read.identity.tagHex),
        _Field('State', r.state),
        _Field('Model', r.model.toUpperCase()),
        if (r.programmedAt != null)
          _Field('Programmed', r.programmedAt!.toLocal().toString()),
        if (r.healthy != null)
          _Field('Health at programming', r.healthy! ? 'passed' : 'FAILED',
              color: r.healthy! ? kGood : kBad),
      ],
      primary: FilledButton(
          onPressed: controller.nextDevice, child: const Text('Next Device')),
    );
  }
}

class _UnknownPanel extends StatelessWidget {
  const _UnknownPanel({required this.state, required this.controller});
  final UnknownSerial state;
  final BenchController controller;

  @override
  Widget build(BuildContext context) => _Panel(
        icon: Icons.help_outline,
        color: kWarn,
        title: 'Unrecognised serial',
        body: [
          _Note(
            'This adapter carries ${state.read.identity.displaySerial}, and the '
            'database has no record of it. Either it was programmed by the old '
            'Python tool and its registry was never uploaded, or it is not '
            'ours. Wiping issues a fresh serial and abandons this one.',
            color: kWarn,
          ),
          _Field('Serial on device', state.read.identity.displaySerial),
          _Field('Tag on device', state.read.identity.tagHex),
          _Field('Scheme version',
              '0x${state.read.identity.version.toRadixString(16).toUpperCase()}'),
          _fingerprintCard(state.fingerprint),
        ],
        primary: FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kWarn),
          onPressed: () => _confirmWipe(context),
          child: const Text('Wipe and reprogram'),
        ),
        secondary: OutlinedButton(
            onPressed: controller.nextDevice, child: const Text('Leave it')),
      );

  Future<void> _confirmWipe(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Wipe this adapter?'),
        content: Text(
          'The identity currently on this device '
          '(${state.read.identity.displaySerial}) will be erased and replaced '
          'with a newly allocated serial. This cannot be undone from here — '
          'the old serial stays unknown to the database.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kWarn),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Wipe and reprogram'),
          ),
        ],
      ),
    );
    if (ok == true) await controller.program(wipeFirst: true);
  }
}

class _SuccessPanel extends StatelessWidget {
  const _SuccessPanel({required this.state, required this.controller});
  final Success state;
  final BenchController controller;

  @override
  Widget build(BuildContext context) {
    final a = state.allocation;
    return _Panel(
      icon: Icons.check_circle,
      color: kGood,
      title: 'Programmed and verified',
      body: [
        // Large, selectable, monospaced: this is the number that gets read
        // onto a label, and misreading it is a returned unit.
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: SelectableText(
              a.displaySerial,
              style: kMono.copyWith(
                  fontSize: 44, fontWeight: FontWeight.w700, color: kGood),
            ),
          ),
        ),
        _Field('Tag', a.tagHex),
        _Field('Model', a.model.label),
        _Field('Adapter', state.adapter.id),
        _Field('Health', _health(state.health),
            color: state.health.ok ? kGood : kBad),
        _Field('Recorded', state.recorded ? 'yes' : 'QUEUED — server unreachable',
            color: state.recorded ? kGood : kWarn),
        if (!state.recorded)
          const _Note(
            'The identity is on the device but the server did not acknowledge '
            'it. The record is in the local journal and will be retried on the '
            'next launch. Do not ship this unit until it shows as recorded.',
            color: kWarn,
          ),
        const _Note(
          'Power-cycle the unit and reconnect to confirm the bytes survived. '
          'That is the check that matters.',
          color: kBrand,
          icon: Icons.power_settings_new,
        ),
      ],
      primary: FilledButton.icon(
        onPressed: controller.nextDevice,
        icon: const Icon(Icons.arrow_forward),
        label: const Text('Next Device'),
      ),
    );
  }

  static String _health(HealthCheck h) =>
      h.ok ? 'passed — ${h.version}, protocol ${h.protocol}' : 'FAILED';
}

class _FailedPanel extends StatelessWidget {
  const _FailedPanel({required this.state, required this.controller});
  final Failed state;
  final BenchController controller;

  @override
  Widget build(BuildContext context) => _Panel(
        icon: Icons.error,
        color: kBad,
        title: state.message,
        body: [
          _Note(state.detail, color: kBad, icon: Icons.error_outline),
          if (state.allocation != null)
            _Field('Serial held', state.allocation!.displaySerial),
        ],
        primary: state.canRetry
            ? FilledButton(
                onPressed: controller.retry, child: const Text('Try again'))
            : FilledButton(
                onPressed: controller.abort, child: const Text('Next Device')),
        secondary: state.canRetry
            ? OutlinedButton(
                onPressed: controller.abort, child: const Text('Abort'))
            : null,
      );
}

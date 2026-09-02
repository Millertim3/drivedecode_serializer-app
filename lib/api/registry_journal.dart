// lib/api/registry_journal.dart
//
// A local append-only record of every unit this bench programmed, in the same
// JSONL shape as 2026/OBDII/Test/registry.jsonl.
//
// TWO JOBS, AND ONLY THE SECOND IS INTERESTING.
//
// First, it is a paper trail. If the database is ever lost or a row is
// questioned, the bench that did the work has its own copy.
//
// Second, and the reason it is not merely a log file: it is the retry queue
// for the window between "the bytes are on the device" and "the server knows".
// That window is small and it is the only place in the flow where a network
// failure costs something real — the adapter is programmed either way, so
// losing the record means a unit in the field whose serial the entitlement
// server has never heard of. Entries land here unconfirmed and are retried on
// the next launch.
//
// WHAT IS DELIBERATELY NOT HERE: any ability to allocate a serial offline.
// See BenchClient's header.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../identity/identity.dart';

class JournalEntry {
  const JournalEntry({
    required this.serial,
    required this.model,
    required this.tagHex,
    required this.version,
    required this.bleAddress,
    required this.programmedAt,
    required this.healthy,
    required this.confirmed,
  });

  final int serial;
  final DeviceModel model;
  final String tagHex;
  final int version;
  final String? bleAddress;
  final DateTime programmedAt;
  final bool healthy;

  /// Whether the server acknowledged this unit. False means the write
  /// succeeded but /confirm did not, and this entry is owed a retry.
  final bool confirmed;

  Map<String, dynamic> toJson() => {
        'serial': serial,
        'model': model.wire,
        'tag': tagHex,
        'version': version,
        'ble_address': bleAddress,
        'programmed_at': programmedAt.toIso8601String(),
        'healthy': healthy,
        'confirmed': confirmed,
      };

  static JournalEntry fromJson(Map<String, dynamic> j) => JournalEntry(
        serial: (j['serial'] as num).toInt(),
        model: DeviceModel.values.firstWhere(
          (m) => m.wire == j['model'],
          orElse: () => DeviceModel.m1,
        ),
        tagHex: j['tag'] as String? ?? '',
        version: (j['version'] as num?)?.toInt() ?? kSchemeVersion,
        bleAddress: j['ble_address'] as String?,
        programmedAt:
            DateTime.tryParse(j['programmed_at'] as String? ?? '') ??
                DateTime.now(),
        healthy: j['healthy'] as bool? ?? false,
        // Absent means the Python tool wrote it, and those were all uploaded
        // by hand. Reading them as unconfirmed would re-POST the entire
        // historical registry on first launch.
        confirmed: j['confirmed'] as bool? ?? true,
      );
}

class RegistryJournal {
  RegistryJournal(this._file);

  final File _file;

  /// Open the journal in the platform's application-support directory —
  /// %APPDATA% on Windows, ~/Library/Application Support on macOS. Not next to
  /// the executable: an app bundle is read-only on macOS and Program Files is
  /// not writable without elevation.
  static Future<RegistryJournal> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return RegistryJournal(File('${dir.path}/registry.jsonl'));
  }

  String get path => _file.path;

  Future<List<JournalEntry>> readAll() async {
    if (!await _file.exists()) return const [];
    final out = <JournalEntry>[];
    for (final line in await _file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        out.add(JournalEntry.fromJson(
            jsonDecode(line) as Map<String, dynamic>));
      } catch (_) {
        // A corrupt line — a half-written record from a bench that lost power
        // mid-append — must not take the rest of the file with it. Skipped,
        // and the file is never rewritten, so the bad line stays visible to a
        // human rather than being quietly dropped.
      }
    }
    return out;
  }

  Future<void> append(JournalEntry entry) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      '${jsonEncode(entry.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// Entries whose hardware write succeeded but whose /confirm did not.
  ///
  /// Deduplicated by serial, latest wins: a retry appends a fresh line rather
  /// than rewriting the file, so a serial that failed and then succeeded
  /// appears twice and only the last state is true.
  Future<List<JournalEntry>> pendingConfirmations() async {
    final latest = <int, JournalEntry>{};
    for (final e in await readAll()) {
      latest[e.serial] = e;
    }
    return latest.values.where((e) => !e.confirmed).toList()
      ..sort((a, b) => a.serial.compareTo(b.serial));
  }
}

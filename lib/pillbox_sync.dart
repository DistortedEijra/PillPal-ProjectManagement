import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';

import 'bluetooth_service.dart';
import 'time_utils.dart';

/// One reminder saved inside the PillPalBox: light [slot] on [dayMask] days
/// (bit 0 = Mon ... bit 6 = Sun) at [hour]:[minute].
class PillBoxEntry {
  final String slot;
  final int dayMask;
  final int hour;
  final int minute;
  const PillBoxEntry(this.slot, this.dayMask, this.hour, this.minute);

  @override
  bool operator ==(Object other) =>
      other is PillBoxEntry &&
      other.slot == slot &&
      other.dayMask == dayMask &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(slot, dayMask, hour, minute);

  @override
  String toString() => '$slot/$dayMask/$hour:$minute';
}

/// The box stores at most this many reminders (see pillpalbox.ino).
const int kPillBoxMaxEntries = 40;

int dayMaskFor(Iterable<String> days) {
  var mask = 0;
  for (final d in days) {
    final i = kDaysOfWeek.indexOf(d);
    if (i >= 0) mask |= 1 << i;
  }
  return mask;
}

/// Turns the active medicines that have a PillPalBox slot into the list the
/// box saves. Same slot + same time on different days are merged.
List<PillBoxEntry> planPillBoxEntries(
  List<Map<String, dynamic>> medicines,
  List<Map<String, String>> assignments,
) {
  final slotByName = <String, String>{};
  for (final a in assignments) {
    final name = (a['medicine'] ?? '').trim().toLowerCase();
    final slot = (a['slot'] ?? '').trim().toUpperCase();
    if (name.isNotEmpty && RegExp(r'^[A-F]$').hasMatch(slot)) slotByName[name] = slot;
  }

  final masks = <String, int>{}; // "A|8|0" -> day mask
  for (final med in medicines) {
    if (med['isActive'] == false) continue;
    final slot = slotByName[(med['name'] ?? '').toString().trim().toLowerCase()];
    if (slot == null) continue;
    final mask = dayMaskFor(((med['repeatDays'] as List?) ?? []).cast<String>());
    if (mask == 0) continue;
    for (final t in ((med['schedules'] as List?) ?? []).cast<TimeOfDay>()) {
      final key = '$slot|${t.hour}|${t.minute}';
      masks[key] = (masks[key] ?? 0) | mask;
    }
  }

  final entries = masks.entries.map((e) {
    final p = e.key.split('|');
    return PillBoxEntry(p[0], e.value, int.parse(p[1]), int.parse(p[2]));
  }).toList()
    ..sort((a, b) => (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute));
  return entries.take(kPillBoxMaxEntries).toList();
}

String _two(int n) => n.toString().padLeft(2, '0');

String pillBoxClockLine(DateTime now) =>
    '#T,${now.year},${now.month},${now.day},${now.hour},${now.minute},${now.second}';

/// Name as the box stores it: plain characters, no commas, max 24.
String pillBoxSafeName(String name) {
  final clean = name.replaceAll(RegExp(r'[^\x20-\x7E]'), '').replaceAll(',', ' ').trim();
  final short = clean.length > 24 ? clean.substring(0, 24).trim() : clean;
  return short.isEmpty ? 'PillPal user' : short;
}

/// The lines sent to the box: set the clock, then replace the reminder list
/// and save who it belongs to.
List<String> pillBoxSyncLines(List<PillBoxEntry> entries, DateTime now,
        {String? ownerUid, String? ownerName}) =>
    [
      pillBoxClockLine(now),
      '#C',
      if (ownerUid != null && ownerUid.isNotEmpty) '#O,$ownerUid,${pillBoxSafeName(ownerName ?? '')}',
      for (final e in entries) '#S,${e.slot},${e.dayMask},${_two(e.hour)},${_two(e.minute)}',
      '#E',
    ];

/// Who last saved a medicine list in the box.
class PillBoxOwner {
  final String uid;
  final String name;
  const PillBoxOwner(this.uid, this.name);
}

/// Reads the box's answer to "#W": "OWNER none" -> empty owner,
/// "OWNER <uid>,<name>" -> that owner, anything else -> null.
PillBoxOwner? parsePillBoxOwner(String line) {
  final t = line.trim();
  if (!t.startsWith('OWNER ')) return null;
  final rest = t.substring(6).trim();
  if (rest == 'none') return const PillBoxOwner('', '');
  final comma = rest.indexOf(',');
  if (comma <= 0) return null;
  return PillBoxOwner(rest.substring(0, comma), rest.substring(comma + 1).trim());
}

/// Sends the reminders to the PillPalBox so it can light the slots by itself,
/// even when the phone is not connected later.
///
/// The box remembers which account saved its list. If another account
/// connects, [confirmReplace] asks that user before their list replaces it.
class PillBoxSync {
  static Future<void>? _running;
  static bool _again = false;
  static List<Map<String, dynamic>> _medicines = const [];
  static List<Map<String, String>> _assignments = const [];
  static String _myUid = '';
  static String _myName = '';

  /// Set by the dashboard: shows "Replace <name>'s medicines?" and returns
  /// true if the user agrees.
  static Future<bool> Function(String ownerName)? confirmReplace;

  /// Called when the user chose to keep the other person's list.
  static void Function(String ownerName)? onKeptOtherList;

  /// The account that last saved a list in the connected box (null = unknown).
  static final ValueNotifier<PillBoxOwner?> boxOwner = ValueNotifier(null);

  /// The user said "keep theirs" during this connection: don't ask again
  /// until the box reconnects.
  static bool _keepOthersThisConnection = false;

  /// Call when the box disconnects.
  static void resetConnection() {
    _keepOthersThisConnection = false;
    boxOwner.value = null;
  }

  /// Call whenever schedules or slots change, and when the box connects.
  /// Does nothing if the box is not connected (it will sync on the next connect).
  static Future<void> sync(
    List<Map<String, dynamic>> medicines,
    List<Map<String, String>> assignments, {
    required String userUid,
    required String userName,
  }) {
    _medicines = List.of(medicines);
    _assignments = List.of(assignments);
    _myUid = userUid;
    _myName = userName;
    if (_running != null) {
      _again = true; // another change came in while sending: send once more after
      return _running!;
    }
    _running = _run().whenComplete(() => _running = null);
    return _running!;
  }

  static Future<bool> _send(String line) async {
    final ok = await BluetoothService().sendSignal(line, appendNewline: true);
    if (!ok) log('PillPalBox sync stopped: could not send "$line"');
    // The box reads Bluetooth with a small buffer; give it time per line.
    await Future.delayed(const Duration(milliseconds: 60));
    return ok;
  }

  /// Asks the box who saved its list ("#W"). Null if the box didn't answer
  /// (an older sketch without this feature).
  static Future<PillBoxOwner?> _askOwner() async {
    final answer = Completer<PillBoxOwner?>();
    var buffer = '';
    final sub = BluetoothService().dataStream.listen((chunk) {
      buffer += chunk;
      final lines = buffer.split(RegExp(r'\r?\n'));
      buffer = lines.removeLast();
      for (final line in lines) {
        final owner = parsePillBoxOwner(line);
        if (owner != null && !answer.isCompleted) answer.complete(owner);
        if (line.trim().startsWith('ERR') && !answer.isCompleted) answer.complete(null);
      }
    });
    try {
      await BluetoothService().sendSignal('#W', appendNewline: true);
      return await answer.future.timeout(const Duration(seconds: 3), onTimeout: () => null);
    } finally {
      await sub.cancel();
    }
  }

  static Future<void> _run() async {
    do {
      _again = false;
      if (!BluetoothService().isConnected) return;

      // Always keep the box's clock right.
      if (!await _send(pillBoxClockLine(DateTime.now()))) return;

      final owner = await _askOwner();
      boxOwner.value = owner;
      final someoneElse = owner != null && owner.uid.isNotEmpty && owner.uid != _myUid;
      if (someoneElse) {
        if (_keepOthersThisConnection) return;
        final replace = await (confirmReplace?.call(owner.name) ?? Future.value(false));
        if (!replace) {
          _keepOthersThisConnection = true;
          onKeptOtherList?.call(owner.name);
          return;
        }
      }

      final entries = planPillBoxEntries(_medicines, _assignments);
      final lines = pillBoxSyncLines(entries, DateTime.now(), ownerUid: _myUid, ownerName: _myName);
      for (final line in lines.skip(1)) {
        // (clock already sent)
        if (!await _send(line)) return;
      }
      boxOwner.value = PillBoxOwner(_myUid, pillBoxSafeName(_myName));
      log('PillPalBox synced: ${entries.length} reminder(s)');
    } while (_again);
  }
}

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

/// The lines sent to the box: set the clock, then replace the reminder list.
List<String> pillBoxSyncLines(List<PillBoxEntry> entries, DateTime now) => [
      '#T,${now.year},${now.month},${now.day},${now.hour},${now.minute},${now.second}',
      '#C',
      for (final e in entries) '#S,${e.slot},${e.dayMask},${_two(e.hour)},${_two(e.minute)}',
      '#E',
    ];

/// Sends the reminders to the PillPalBox so it can light the slots by itself,
/// even when the phone is not connected later.
class PillBoxSync {
  static Future<void>? _running;
  static bool _again = false;
  static List<Map<String, dynamic>> _medicines = const [];
  static List<Map<String, String>> _assignments = const [];

  /// Call whenever schedules or slots change, and when the box connects.
  /// Does nothing if the box is not connected (it will sync on the next connect).
  static Future<void> sync(
    List<Map<String, dynamic>> medicines,
    List<Map<String, String>> assignments,
  ) {
    _medicines = List.of(medicines);
    _assignments = List.of(assignments);
    if (_running != null) {
      _again = true; // another change came in while sending: send once more after
      return _running!;
    }
    _running = _run().whenComplete(() => _running = null);
    return _running!;
  }

  static Future<void> _run() async {
    do {
      _again = false;
      if (!BluetoothService().isConnected) return;
      final entries = planPillBoxEntries(_medicines, _assignments);
      final lines = pillBoxSyncLines(entries, DateTime.now());
      for (final line in lines) {
        final ok = await BluetoothService().sendSignal(line, appendNewline: true);
        if (!ok) {
          log('PillPalBox sync stopped: could not send "$line"');
          return;
        }
        // The box reads Bluetooth with a small buffer; give it time per line.
        await Future.delayed(const Duration(milliseconds: 60));
      }
      log('PillPalBox synced: ${entries.length} reminder(s)');
    } while (_again);
  }
}

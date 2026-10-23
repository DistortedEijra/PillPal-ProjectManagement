import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_service.dart';
import 'time_utils.dart';

/// One weekly alarm: all medicines due on the same weekday + time share it.
class PlannedReminder {
  final int id;
  final int weekday; // Monday = 1 ... Sunday = 7
  final TimeOfDay time;
  final String title;
  final String body;
  final String payload;

  const PlannedReminder({
    required this.id,
    required this.weekday,
    required this.time,
    required this.title,
    required this.body,
    required this.payload,
  });
}

/// Builds the list of weekly alarms from the user's active schedules.
/// [medicines] use the dashboard format: name, dosage, schedules (TimeOfDay),
/// repeatDays ('Mon'..'Sun'), isActive.
List<PlannedReminder> planWeeklyReminders(
  List<Map<String, dynamic>> medicines,
  List<Map<String, String>> pillBoxAssignments,
) {
  // key "weekday|hour|minute" -> medicines due then
  final Map<String, List<Map<String, String>>> groups = {};

  for (final med in medicines) {
    if (med['isActive'] == false) continue;
    final name = (med['name'] ?? '').toString();
    if (name.isEmpty) continue;
    final days = ((med['repeatDays'] as List?) ?? []).cast<String>();
    final times = ((med['schedules'] as List?) ?? []).cast<TimeOfDay>();
    final assignment = pillBoxAssignments.firstWhere(
      (a) => (a['medicine'] ?? '').trim().toLowerCase() == name.trim().toLowerCase(),
      orElse: () => <String, String>{},
    );
    final slot = (assignment['slot'] ?? '').toUpperCase();

    for (final day in days) {
      final weekday = kDaysOfWeek.indexOf(day) + 1;
      if (weekday == 0) continue;
      for (final t in times) {
        final key = '$weekday|${t.hour}|${t.minute}';
        final list = groups.putIfAbsent(key, () => []);
        if (!list.any((m) => m['name'] == name)) {
          list.add({'name': name, 'dosage': (med['dosage'] ?? '').toString(), 'slot': slot});
        }
      }
    }
  }

  final plan = <PlannedReminder>[];
  final keys = groups.keys.toList()..sort();
  for (final key in keys) {
    final parts = key.split('|');
    final weekday = int.parse(parts[0]);
    final time = TimeOfDay(hour: int.parse(parts[1]), minute: int.parse(parts[2]));
    final meds = groups[key]!;
    plan.add(PlannedReminder(
      id: stableId('weekly_reminder|$key'),
      weekday: weekday,
      time: time,
      title: 'Medicine Reminder',
      body: meds.length > 1 ? '${meds.length} medicines are due.' : 'Time to take your ${meds.first['name']}.',
      // date is left empty: the confirmation dialog uses "today" when it opens.
      payload: jsonEncode({'medicines': meds, 'date': '', 'time': formatTime12h(time)}),
    ));
  }
  return plan;
}

/// Registers the reminders as real Android alarms so they pop up even when
/// PillPal is closed (before, reminders only fired while the app was open).
class ReminderScheduler {
  static const String _idsKey = 'scheduled_reminder_ids';

  /// Replaces all previously scheduled weekly reminders with the current plan.
  /// Returns how many reminders are now scheduled.
  static Future<int> sync(
    List<Map<String, dynamic>> medicines,
    List<Map<String, String>> pillBoxAssignments,
  ) async {
    await cancelAll();
    final plan = planWeeklyReminders(medicines, pillBoxAssignments);
    final scheduled = <String>[];
    for (final r in plan) {
      try {
        await NotificationService().scheduleWeeklyNotification(
          id: r.id,
          title: r.title,
          body: r.body,
          day: r.weekday,
          time: r.time,
          payload: r.payload,
        );
        scheduled.add('${r.id}');
      } catch (e) {
        debugPrint('Could not schedule reminder ${r.id}: $e');
      }
    }
    final store = await SharedPreferences.getInstance();
    await store.setStringList(_idsKey, scheduled);
    return scheduled.length;
  }

  /// Cancels every weekly reminder this app scheduled (used on logout too).
  static Future<void> cancelAll() async {
    final store = await SharedPreferences.getInstance();
    for (final id in store.getStringList(_idsKey) ?? const <String>[]) {
      final n = int.tryParse(id);
      if (n != null) await NotificationService().cancelNotification(id: n);
    }
    await store.remove(_idsKey);
  }
}

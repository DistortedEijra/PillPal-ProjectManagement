import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'background_tasks.dart';
import 'escalation_service.dart';
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
  final List<Map<String, String>> meds;

  const PlannedReminder({
    required this.id,
    required this.weekday,
    required this.time,
    required this.title,
    required this.body,
    required this.payload,
    this.meds = const [],
  });

  String get key => '$weekday|${time.hour}|${time.minute}';
}

/// The notification id of the weekly reminder for [weekday] (Mon = 1) at [time].
/// The in-app check uses the same id, so a reminder never shows twice.
int reminderIdFor(int weekday, TimeOfDay time) =>
    stableId('weekly_reminder|$weekday|${time.hour}|${time.minute}');

/// Orders reminders by when they next ring, soonest first.
List<PlannedReminder> soonestFirst(List<PlannedReminder> plan, DateTime now) {
  final next = {for (final r in plan) r: nextWeeklyAt(r.weekday, r.time.hour, r.time.minute, from: now)};
  return List.of(plan)..sort((a, b) => next[a]!.compareTo(next[b]!));
}

/// Builds the list of weekly reminder alarms from the user's active schedules.
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
      id: reminderIdFor(weekday, time),
      weekday: weekday,
      time: time,
      title: 'Medicine Reminder',
      body: meds.length > 1 ? '${meds.length} medicines are due.' : 'Time to take your ${meds.first['name']}.',
      // date is left empty: the confirmation dialog uses "today" when it opens.
      payload: jsonEncode({'medicines': meds, 'date': '', 'time': formatTime12h(time)}),
      meds: meds,
    ));
  }
  return plan;
}

/// The +10 and +20 minute follow-up alarms for one reminder. They open the same
/// Yes/No confirmation as the reminder itself.
List<PlannedReminder> planFollowUps(PlannedReminder r) {
  final names = r.meds.map((m) => m['name']).join(', ');
  final result = <PlannedReminder>[];
  for (final level in [1, 2]) {
    final offset = level == 1 ? EscalationService.followUp1 : EscalationService.followUp2;
    final (weekday, time) = shiftWeekly(r.weekday, r.time, offset.inMinutes);
    result.add(PlannedReminder(
      id: stableId('weekly_followup|${r.key}|$level'),
      weekday: weekday,
      time: time,
      title: level == 1 ? 'Reminder: $names not confirmed' : 'Last reminder: $names',
      body: level == 1
          ? "You haven't confirmed your ${formatTime12h(r.time)} medicine yet. Please take it now."
          : 'Confirm within 10 minutes or it will be marked as missed and your caregiver will be alerted.',
      payload: r.payload,
      meds: r.meds,
    ));
  }
  return result;
}

/// The background missed-dose check for one reminder (runs ~31 min after it).
({int id, int weekday, TimeOfDay time, Map<String, dynamic> params}) planDueCheck(PlannedReminder r) {
  final (weekday, time) = shiftWeekly(r.weekday, r.time, EscalationService.missedAfter.inMinutes + 1);
  return (
    id: stableId('weekly_due_check|${r.key}'),
    weekday: weekday,
    time: time,
    params: {
      'weekday': weekday,
      'hour': time.hour,
      'minute': time.minute,
      'time': formatTime12h(r.time),
      'meds': r.meds.map((m) => {'name': m['name'] ?? '', 'dosage': m['dosage'] ?? ''}).toList(),
    },
  );
}

/// Registers the reminders as real Android alarms so they pop up even when
/// PillPal is closed, plus the follow-ups and the background missed-dose check.
class ReminderScheduler {
  static const String _idsKey = 'scheduled_reminder_ids';
  static const String _bgIdsKey = 'scheduled_background_ids';
  static List<PlannedReminder> _lastPlan = const [];

  // Only one sync runs at a time; changes that arrive meanwhile are applied
  // right after it (editing a medicine used to start two syncs at once).
  static Future<int>? _running;
  static bool _again = false;
  static List<Map<String, dynamic>> _medicines = const [];
  static List<Map<String, String>> _assignments = const [];
  static int _generation = 0; // bumped by cancelAll() to stop a running sync

  /// Replaces all previously scheduled alarms with the current plan.
  /// Returns how many reminders are now scheduled.
  static Future<int> sync(
    List<Map<String, dynamic>> medicines,
    List<Map<String, String>> pillBoxAssignments,
  ) {
    _medicines = List.of(medicines);
    _assignments = List.of(pillBoxAssignments);
    if (_running != null) {
      _again = true;
      return _running!;
    }
    _running = _runSyncs().whenComplete(() => _running = null);
    return _running!;
  }

  static Future<int> _runSyncs() async {
    int count;
    do {
      _again = false;
      count = await _syncOnce(_medicines, _assignments, _generation);
    } while (_again);
    return count;
  }

  static Future<int> _syncOnce(
    List<Map<String, dynamic>> medicines,
    List<Map<String, String>> pillBoxAssignments,
    int generation,
  ) async {
    // Soonest first: a dose set for the next minute gets its alarm right away
    // instead of after every other alarm (registering them all takes a while).
    final plan = soonestFirst(planWeeklyReminders(medicines, pillBoxAssignments), DateTime.now());
    _lastPlan = plan;
    final notificationIds = <String>[];
    final backgroundIds = <String>[];
    int reminders = 0;

    // Reminders first, then follow-ups, then background checks.
    for (final r in plan) {
      if (generation != _generation) return _abort(notificationIds, backgroundIds); // logged out meanwhile
      if (await _schedule(r)) {
        notificationIds.add('${r.id}');
        reminders++;
      }
    }
    for (final r in plan) {
      if (generation != _generation) return _abort(notificationIds, backgroundIds);
      for (final f in planFollowUps(r)) {
        if (await _schedule(f)) notificationIds.add('${f.id}');
      }
    }
    for (final r in plan) {
      if (generation != _generation) return _abort(notificationIds, backgroundIds);
      final check = planDueCheck(r);
      try {
        final ok = await BackgroundTasks.scheduleDueCheck(
          id: check.id,
          at: nextWeeklyAt(check.weekday, check.time.hour, check.time.minute),
          params: check.params,
        );
        if (ok) backgroundIds.add('${check.id}');
      } catch (e) {
        debugPrint('Could not schedule background check ${check.id}: $e');
      }
    }

    // Scheduling an id again replaces it, so only alarms that are no longer
    // in the plan (old times, deleted medicines) need cancelling.
    final store = await SharedPreferences.getInstance();
    final oldIds = (store.getStringList(_idsKey) ?? const <String>[]).toSet()..removeAll(notificationIds);
    final oldBgIds = (store.getStringList(_bgIdsKey) ?? const <String>[]).toSet()..removeAll(backgroundIds);
    for (final id in oldIds) {
      final n = int.tryParse(id);
      if (n != null) await NotificationService().cancelNotification(id: n);
    }
    for (final id in oldBgIds) {
      final n = int.tryParse(id);
      if (n != null) {
        try {
          await BackgroundTasks.cancel(n);
        } catch (_) {}
      }
    }
    if (generation != _generation) return _abort(notificationIds, backgroundIds);
    await store.setStringList(_idsKey, notificationIds);
    await store.setStringList(_bgIdsKey, backgroundIds);
    return reminders;
  }

  /// Logged out during a sync: remove the alarms this sync already set.
  static Future<int> _abort(List<String> ids, List<String> bgIds) async {
    for (final id in ids) {
      await NotificationService().cancelNotification(id: int.parse(id));
    }
    for (final id in bgIds) {
      try {
        await BackgroundTasks.cancel(int.parse(id));
      } catch (_) {}
    }
    return 0;
  }

  static Future<bool> _schedule(PlannedReminder r, {DateTime? notBefore}) async {
    try {
      await NotificationService().scheduleWeeklyNotification(
        id: r.id,
        title: r.title,
        body: r.body,
        day: r.weekday,
        time: r.time,
        payload: r.payload,
        notBefore: notBefore,
      );
      return true;
    } catch (e) {
      debugPrint('Could not schedule reminder ${r.id}: $e');
      return false;
    }
  }

  /// Call after the user answers Yes/No: this dose's follow-ups are not needed
  /// today, so they are moved to next week.
  static Future<void> skipFollowUpsFor({required String date, required String time}) async {
    final t = parseTime12h(time);
    final day = DateTime.tryParse(date.isEmpty ? dateKey(DateTime.now()) : date);
    if (t == null || day == null) return;
    final reminder = _lastPlan.where((r) => r.weekday == day.weekday && r.time == t);
    if (reminder.isEmpty) return;
    final due = DateTime(day.year, day.month, day.day, t.hour, t.minute);
    for (final f in planFollowUps(reminder.first)) {
      await NotificationService().cancelNotification(id: f.id);
      // Anything up to 1 hour after this dose belongs to today's dose.
      await _schedule(f, notBefore: due.add(const Duration(hours: 1)));
    }
  }

  /// Cancels every alarm this app scheduled (used on logout too).
  static Future<void> cancelAll() async {
    _generation++; // stops a sync that is still running
    _again = false;
    final store = await SharedPreferences.getInstance();
    for (final id in store.getStringList(_idsKey) ?? const <String>[]) {
      final n = int.tryParse(id);
      if (n != null) await NotificationService().cancelNotification(id: n);
    }
    for (final id in store.getStringList(_bgIdsKey) ?? const <String>[]) {
      final n = int.tryParse(id);
      if (n != null) {
        try {
          await BackgroundTasks.cancel(n);
        } catch (_) {}
      }
    }
    await store.remove(_idsKey);
    await store.remove(_bgIdsKey);
  }
}

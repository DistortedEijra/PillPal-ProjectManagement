// Reminders that fire when the app is closed: checks which weekly alarms
// are created from the user's schedules.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp4/reminder_scheduler.dart';

Map<String, dynamic> med(String name, List<String> days, List<TimeOfDay> times,
        {bool active = true, String dosage = '1 tablet'}) =>
    {'name': name, 'dosage': dosage, 'repeatDays': days, 'schedules': times, 'isActive': active};

const eight = TimeOfDay(hour: 8, minute: 0);
const twenty = TimeOfDay(hour: 20, minute: 0);

void main() {
  test('one alarm per day and time', () {
    final plan = planWeeklyReminders([med('Losartan', ['Mon', 'Wed'], [eight, twenty])], []);
    expect(plan.length, 4);
    expect(plan.map((p) => p.weekday).toSet(), {1, 3});
    expect(plan.first.body, 'Time to take your Losartan.');
    expect(plan.first.title, 'Medicine Reminder');
  });

  test('medicines due at the same time share one alarm', () {
    final plan = planWeeklyReminders([
      med('Losartan', ['Mon'], [eight]),
      med('Metformin', ['Mon'], [eight]),
    ], []);
    expect(plan.length, 1);
    expect(plan.single.body, '2 medicines are due.');
    final payload = jsonDecode(plan.single.payload) as Map<String, dynamic>;
    expect((payload['medicines'] as List).map((m) => m['name']), ['Losartan', 'Metformin']);
    expect(payload['time'], '8:00 AM');
  });

  test('deleted (inactive) schedules get no alarm', () {
    final plan = planWeeklyReminders([med('Old', ['Mon'], [eight], active: false)], []);
    expect(plan, isEmpty);
  });

  test('PillPalBox slot goes into the alarm so the box lights up', () {
    final plan = planWeeklyReminders(
      [med('Losartan', ['Sun'], [eight])],
      [{'slot': 'b', 'medicine': 'losartan '}],
    );
    final payload = jsonDecode(plan.single.payload) as Map<String, dynamic>;
    expect((payload['medicines'] as List).single['slot'], 'B');
    expect(plan.single.weekday, 7);
  });

  test('alarm ids are stable, so re-syncing replaces instead of duplicating', () {
    final a = planWeeklyReminders([med('Losartan', ['Mon'], [eight])], []);
    final b = planWeeklyReminders([med('Losartan', ['Mon'], [eight])], []);
    expect(a.single.id, b.single.id);
  });
}

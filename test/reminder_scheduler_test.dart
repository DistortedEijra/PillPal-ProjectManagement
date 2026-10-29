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

  test('each reminder gets follow-ups at +10 and +20 minutes', () {
    final r = planWeeklyReminders([med('Losartan', ['Mon'], [eight])], []).single;
    final f = planFollowUps(r);
    expect(f.map((x) => x.weekday), [1, 1]);
    expect(f.map((x) => x.time), [const TimeOfDay(hour: 8, minute: 10), const TimeOfDay(hour: 8, minute: 20)]);
    expect(f.first.payload, r.payload); // opens the same Yes/No confirmation
    expect(f.map((x) => x.id).toSet().length, 2);
  });

  test('follow-ups late on Sunday night roll over to Monday', () {
    final r = planWeeklyReminders([med('Late', ['Sun'], [const TimeOfDay(hour: 23, minute: 55)])], []).single;
    final f = planFollowUps(r);
    expect(f.first.weekday, 1);
    expect(f.first.time, const TimeOfDay(hour: 0, minute: 5));
  });

  test('background missed-dose check runs 31 minutes after the reminder', () {
    final r = planWeeklyReminders([med('Losartan', ['Wed'], [twenty])], []).single;
    final c = planDueCheck(r);
    expect(c.weekday, 3);
    expect(c.time, const TimeOfDay(hour: 20, minute: 31));
    expect(c.params['time'], '8:00 PM');
    expect((c.params['meds'] as List).single['name'], 'Losartan');
  });

  test('the dose due soonest is scheduled first', () {
    // Friday 30 Oct 2026, 00:31: a dose at 00:32 today comes before Monday 8:00.
    final now = DateTime(2026, 10, 30, 0, 31, 40);
    final plan = planWeeklyReminders([
      med('Metformin', ['Mon'], [eight]),
      med('Losartan', ['Fri'], [const TimeOfDay(hour: 0, minute: 32)]),
      med('Vitamin D3', ['Fri'], [twenty]),
    ], []);
    final ordered = soonestFirst(plan, now);
    expect(ordered.map((r) => r.meds.first['name']), ['Losartan', 'Vitamin D3', 'Metformin']);
  });

  test('in-app reminder uses the same id as the weekly alarm', () {
    final plan = planWeeklyReminders([med('Losartan', ['Fri'], [eight])], []);
    expect(plan.single.id, reminderIdFor(5, eight));
  });
}

// Limited-time medicines ("for 1 week"): end dates, alarms, box list, scanning.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp4/pillbox_sync.dart';
import 'package:myapp4/reminder_scheduler.dart';
import 'package:myapp4/scan_to_schedule.dart';
import 'package:myapp4/time_utils.dart';

Map<String, dynamic> med(String name, List<String> days, List<TimeOfDay> times, {String? endDate}) => {
      'name': name,
      'dosage': '1 capsule',
      'repeatDays': days,
      'schedules': times,
      'isActive': true,
      'endDate': endDate,
    };

const eight = TimeOfDay(hour: 8, minute: 0);
const twenty = TimeOfDay(hour: 20, minute: 0);
const everyDay = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

// Friday 30 Oct 2026, 9:00 AM
final friMorning = DateTime(2026, 10, 30, 9, 0);

void main() {
  group('dates', () {
    test('"7 days" starting today ends 6 days later', () {
      expect(endDateForDays(7, from: DateTime(2026, 10, 30, 15)), '2026-11-05');
      expect(endDateForDays(1, from: DateTime(2026, 10, 30)), '2026-10-30');
    });

    test('the last day still counts, the day after does not', () {
      expect(runsOn('2026-11-05', DateTime(2026, 11, 5, 23, 59)), isTrue);
      expect(runsOn('2026-11-05', DateTime(2026, 11, 6, 0, 1)), isFalse);
      expect(runsOn(null, DateTime(2030)), isTrue); // ongoing
      expect(runsOn('', DateTime(2030)), isTrue);
    });

    test('course text', () {
      expect(courseText('2026-11-05', now: DateTime(2026, 10, 30)), 'Until Nov 5 (7 days left)');
      expect(courseText('2026-11-05', now: DateTime(2026, 11, 5, 20)), 'Last day today');
      expect(courseText('2026-11-05', now: DateTime(2026, 11, 7)), 'Ended Nov 5');
      expect(courseText(null), 'Ongoing');
    });
  });

  group('alarms', () {
    test('a course ending Monday rings once on each remaining dose, not weekly', () {
      final plan = planWeeklyReminders(
        [med('Amoxicillin', everyDay, [eight, twenty], endDate: '2026-11-02')],
        [],
        now: friMorning,
      );
      // Fri 8 PM, Sat x2, Sun x2, Mon x2. Fri 8 AM already passed; Tue-Thu are after the end.
      expect(plan.length, 7);
      expect(plan.every((r) => r.onceAt != null), isTrue);
      final first = soonestFirst(plan, friMorning).first;
      expect(first.onceAt, DateTime(2026, 10, 30, 20, 0));
      expect(planFollowUps(first).first.onceAt, DateTime(2026, 10, 30, 20, 10));
    });

    test('a finished course gets no alarms', () {
      final plan = planWeeklyReminders(
        [med('Amoxicillin', everyDay, [eight], endDate: '2026-10-29')],
        [],
        now: friMorning,
      );
      expect(plan, isEmpty);
    });

    test('a long course and ongoing medicines stay weekly', () {
      final plan = planWeeklyReminders(
        [
          med('Amoxicillin', ['Sat'], [eight], endDate: '2026-11-02'),
          med('Losartan', ['Sat'], [eight]),
          med('Antibiotic', ['Sun'], [eight], endDate: '2026-12-31'),
        ],
        [],
        now: friMorning,
      );
      expect(plan.length, 2);
      expect(plan.every((r) => r.onceAt == null), isTrue); // Sat shared with Losartan
      final check = planDueCheck(plan.firstWhere((r) => r.weekday == 6));
      final amox = (check.params['meds'] as List).firstWhere((m) => m['name'] == 'Amoxicillin');
      expect(amox['endDate'], '2026-11-02'); // the background check skips it after that
    });
  });

  test('PillPalBox only gets the days still inside the course', () {
    final entries = planPillBoxEntries(
      [med('Amoxicillin', everyDay, [eight, twenty], endDate: '2026-11-02')],
      [{'slot': 'A', 'medicine': 'Amoxicillin'}],
      now: friMorning,
    );
    // 8 AM: Sat, Sun, Mon = 32 + 64 + 1. 8 PM: Fri too = + 16.
    expect(entries, [const PillBoxEntry('A', 97, 8, 0), const PillBoxEntry('A', 113, 20, 0)]);
  });

  group('scanning "for N days"', () {
    test('reads the course length', () {
      expect(PrescriptionParser.durationDaysIn('1 cap 3x a day x 7 days'), 7);
      expect(PrescriptionParser.durationDaysIn('Take for 2 weeks'), 14);
      expect(PrescriptionParser.durationDaysIn('for 1 month'), 30);
      expect(PrescriptionParser.durationDaysIn('sa loob ng 5 araw'), 5);
      expect(PrescriptionParser.durationDaysIn('1 tab once a day'), isNull);
    });

    test('printed label fills durationDays', () {
      final r = PrescriptionParser.parse('Amoxicillin 500mg\n1 cap TID for 7 days');
      expect(r.durationDays, 7);
      expect(PrescriptionParser.parse('Losartan 50mg\n1 tab once a day').durationDays, isNull);
    });
  });
}

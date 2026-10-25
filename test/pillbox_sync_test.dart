// PillPalBox offline reminders: checks the list the app sends to the box.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp4/pillbox_sync.dart';

Map<String, dynamic> med(String name, List<String> days, List<TimeOfDay> times, {bool active = true}) =>
    {'name': name, 'dosage': '1 tablet', 'repeatDays': days, 'schedules': times, 'isActive': active};

const eight = TimeOfDay(hour: 8, minute: 0);
const twenty = TimeOfDay(hour: 20, minute: 0);

void main() {
  test('day mask: Mon = 1 ... Sun = 64', () {
    expect(dayMaskFor(['Mon']), 1);
    expect(dayMaskFor(['Sun']), 64);
    expect(dayMaskFor(['Mon', 'Wed', 'Fri']), 1 + 4 + 16);
    expect(dayMaskFor(['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']), 127);
  });

  test('only medicines with a slot are sent, one entry per time', () {
    final entries = planPillBoxEntries(
      [
        med('Losartan', ['Mon', 'Tue'], [eight, twenty]),
        med('Vitamin C', ['Mon'], [eight]), // no slot
      ],
      [
        {'slot': 'A', 'medicine': 'losartan'},
        {'slot': 'B', 'medicine': ''}, // empty slot
      ],
    );
    expect(entries, [const PillBoxEntry('A', 3, 8, 0), const PillBoxEntry('A', 3, 20, 0)]);
  });

  test('deleted medicines are not sent', () {
    final entries = planPillBoxEntries(
      [med('Losartan', ['Mon'], [eight], active: false)],
      [{'slot': 'A', 'medicine': 'Losartan'}],
    );
    expect(entries, isEmpty);
  });

  test('sync lines: clock first, then the list, then save', () {
    final lines = pillBoxSyncLines(
      [const PillBoxEntry('C', 127, 8, 5)],
      DateTime(2026, 10, 25, 20, 43, 7),
    );
    expect(lines, ['#T,2026,10,25,20,43,7', '#C', '#S,C,127,08,05', '#E']);
  });

  test('the box keeps at most 40 reminders', () {
    final times = [for (int m = 0; m < 50; m++) TimeOfDay(hour: m ~/ 60 + 6, minute: m % 60)];
    final entries = planPillBoxEntries(
      [med('Losartan', ['Mon'], times)],
      [{'slot': 'A', 'medicine': 'Losartan'}],
    );
    expect(entries.length, kPillBoxMaxEntries);
  });
}

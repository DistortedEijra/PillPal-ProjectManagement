// Basic helper tests (replaces the default Flutter counter test, which
// does not apply to PillPal).
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp4/caregiver_service.dart';
import 'package:myapp4/time_utils.dart';

void main() {
  group('time_utils', () {
    test('formatTime12h matches the History tab format', () {
      expect(formatTime12h(const TimeOfDay(hour: 0, minute: 5)), '12:05 AM');
      expect(formatTime12h(const TimeOfDay(hour: 8, minute: 0)), '8:00 AM');
      expect(formatTime12h(const TimeOfDay(hour: 12, minute: 0)), '12:00 PM');
      expect(formatTime12h(const TimeOfDay(hour: 20, minute: 30)), '8:30 PM');
    });

    test('dateKey is yyyy-MM-dd', () {
      expect(dateKey(DateTime(2026, 3, 7)), '2026-03-07');
      expect(dateKey(DateTime(2026, 10, 23, 23, 59)), '2026-10-23');
    });

    test('stableId is stable, positive, and differs per input', () {
      expect(stableId('a'), stableId('a'));
      expect(stableId('Losartan|2026-10-23|8:00 AM#1'),
          isNot(stableId('Losartan|2026-10-23|8:00 AM#2')));
      expect(stableId('anything'), greaterThanOrEqualTo(0));
      expect(stableId('anything'), lessThan(0x80000000));
    });
  });

  group('weekly time helpers', () {
    test('parseTime12h reads the History format back', () {
      expect(parseTime12h('8:00 AM'), const TimeOfDay(hour: 8, minute: 0));
      expect(parseTime12h('12:05 AM'), const TimeOfDay(hour: 0, minute: 5));
      expect(parseTime12h('12:00 PM'), const TimeOfDay(hour: 12, minute: 0));
      expect(parseTime12h('8:30 PM'), const TimeOfDay(hour: 20, minute: 30));
      expect(parseTime12h('nonsense'), isNull);
    });

    test('nextWeeklyAt finds the next matching day and time', () {
      final fri0900 = DateTime(2026, 10, 23, 9, 0); // a Friday
      expect(nextWeeklyAt(5, 10, 0, from: fri0900), DateTime(2026, 10, 23, 10, 0));
      expect(nextWeeklyAt(5, 8, 0, from: fri0900), DateTime(2026, 10, 30, 8, 0));
      expect(nextWeeklyAt(1, 8, 0, from: fri0900), DateTime(2026, 10, 26, 8, 0));
    });
  });

  group('invite code', () {
    test('is 6 easy-to-read characters', () {
      final rnd = Random(1);
      for (int i = 0; i < 200; i++) {
        final code = generateInviteCode(rnd);
        expect(code.length, 6);
        for (final c in code.split('')) {
          expect(kInviteAlphabet.contains(c), isTrue, reason: 'bad char $c in $code');
        }
        expect(code.contains(RegExp('[01IO]')), isFalse);
      }
    });
  });
}

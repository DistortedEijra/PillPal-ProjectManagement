// Scan-to-Schedule: checks that the prescription reader turns common label
// wording into the right name, dosage, times and days.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp4/scan_to_schedule.dart';
import 'package:myapp4/time_utils.dart';

List<String> times(ScanResult r) => r.times.map(formatTime12h).toList();

void main() {
  test('Amoxicillin, 3x a day', () {
    final r = PrescriptionParser.parse(
        'Rx\nAmoxicillin 500mg capsule\nSig: Take 1 capsule 3x a day for 7 days\nQty: 21 capsules');
    expect(r.name, 'Amoxicillin');
    expect(r.dosage, '1 capsule (500 mg)');
    expect(times(r), ['8:00 AM', '2:00 PM', '8:00 PM']);
    expect(r.days, kDaysOfWeek);
    expect(r.foundFrequency, isTrue);
  });

  test('Losartan, once daily, skips doctor and patient lines', () {
    final r = PrescriptionParser.parse(
        'Dr. Juan Santos MD\nPatient: Maria Cruz\nLosartan 50 mg tablet\nTake one tablet once daily in the morning');
    expect(r.name, 'Losartan');
    expect(r.dosage, '1 tablet (50 mg)');
    expect(times(r), ['8:00 AM']);
  });

  test('Metformin, BID, ignores pill count', () {
    final r = PrescriptionParser.parse('METFORMIN 500 MG\nTake 1 tab BID after meals\n#60 tablets');
    expect(r.name, 'Metformin');
    expect(r.dosage, '1 tablet (500 mg)');
    expect(times(r), ['8:00 AM', '8:00 PM']);
  });

  test('every 6 hours', () {
    final r = PrescriptionParser.parse('Paracetamol 500mg\n1 tablet every 6 hours as needed');
    expect(r.name, 'Paracetamol');
    expect(times(r), ['8:00 AM', '2:00 PM', '8:00 PM', '2:00 AM']);
  });

  test('q8h shorthand', () {
    final r = PrescriptionParser.parse('Cefalexin 500mg\n1 cap q8h');
    expect(times(r), ['8:00 AM', '4:00 PM', '12:00 AM']);
  });

  test('QID = 4 times a day', () {
    final r = PrescriptionParser.parse('Salbutamol 2mg\n1 tab QID');
    expect(times(r), ['8:00 AM', '12:00 PM', '4:00 PM', '8:00 PM']);
  });

  test('at bedtime', () {
    final r = PrescriptionParser.parse('Simvastatin 20mg\nTake 1 tablet at bedtime');
    expect(r.name, 'Simvastatin');
    expect(times(r), ['9:00 PM']);
  });

  test('exact clock times, sorted, including 12 AM / 12 PM', () {
    final r = PrescriptionParser.parse('Amlodipine 5mg\nTake 1 tablet at 8:00 PM, 12 AM and 12:00 PM');
    expect(times(r), ['12:00 AM', '12:00 PM', '8:00 PM']);
  });

  test('"10 amoxicillin" is not read as 10 AM', () {
    final r = PrescriptionParser.parse('Dispense 10 amoxicillin capsules\nTake 1 capsule daily');
    expect(times(r), ['8:00 AM']);
  });

  test('quantity like "Qty: 30 tablets" is not used as the dose', () {
    final r = PrescriptionParser.parse('Losartan 50mg\nQty: 30 tablets\nonce daily');
    expect(r.dosage, '50 mg');
  });

  test('weekly medicine is set to one day', () {
    final r = PrescriptionParser.parse('Alendronate 70mg\nTake 1 tablet once a week');
    expect(r.days, ['Mon']);
  });

  test('nothing readable: safe defaults and a helpful message', () {
    final r = PrescriptionParser.parse('');
    expect(r.name, isNull);
    expect(r.dosage, isNull);
    expect(r.foundFrequency, isFalse);
    expect(r.times, [const TimeOfDay(hour: 8, minute: 0)]);
    expect(r.summary, contains("Couldn't read"));
  });

  test('summary lists what was and was not found', () {
    final r = PrescriptionParser.parse('Losartan 50mg');
    expect(r.summary, contains('Found: name, dosage'));
    expect(r.summary, contains('Not found: schedule'));
  });

  group('several medicines on one prescription', () {
    test('each medicine gets its own name, dose and times', () {
      final all = PrescriptionParser.parseAll(
        'Rx\n'
        '1. Amoxicillin 500mg\n'
        'Take 1 capsule 3x a day\n'
        '2. Paracetamol 500mg\n'
        'Take 1 tablet every 6 hours\n'
        '3. Cetirizine 10mg\n'
        'Take 1 tablet once daily at bedtime',
      );
      expect(all.map((r) => r.name), ['Amoxicillin', 'Paracetamol', 'Cetirizine']);
      expect(all[0].times.length, 3);
      expect(all[1].times.length, 4);
      expect(all[2].times, [const TimeOfDay(hour: 21, minute: 0)]);
      expect(all[0].dosage, '1 capsule (500 mg)');
    });

    test('a single medicine still returns one result', () {
      final all = PrescriptionParser.parseAll('Losartan 50mg\nTake 1 tablet once daily');
      expect(all.length, 1);
      expect(all.single.name, 'Losartan');
    });
  });

  group('days', () {
    test('specific days: "every Mon, Wed and Fri"', () {
      final r = PrescriptionParser.parse('Losartan 50mg\nTake 1 tab every Mon, Wed and Fri at 8am');
      expect(r.days, ['Mon', 'Wed', 'Fri']);
      expect(times(r), ['8:00 AM']);
      expect(r.foundDays, isTrue);
      expect(r.summary, contains('days (Mon, Wed, Fri)'));
    });

    test('MWF and TTh codes', () {
      expect(PrescriptionParser.parse('Iron 1 tab MWF').days, ['Mon', 'Wed', 'Fri']);
      expect(PrescriptionParser.parse('Vitamin D 1 cap TTh').days, ['Tue', 'Thu']);
    });

    test('ranges and weekdays', () {
      expect(PrescriptionParser.parse('1 tab daily, Monday to Friday').days,
          ['Mon', 'Tue', 'Wed', 'Thu', 'Fri']);
      expect(PrescriptionParser.parse('1 tab daily on weekdays').days, ['Mon', 'Tue', 'Wed', 'Thu', 'Fri']);
    });

    test('Tagalog days', () {
      final r = PrescriptionParser.parse('Inumin ang 1 tableta tuwing Lunes at Huwebes');
      expect(r.days, ['Mon', 'Thu']);
      expect(r.dosage, '1 tablet');
    });

    test('twice a week is spread out, and is not twice a day', () {
      final r = PrescriptionParser.parse('Methotrexate 2.5mg\n1 tab twice a week');
      expect(r.days, ['Mon', 'Thu']);
      expect(times(r), ['8:00 AM']);
    });

    test('every other day', () {
      final r = PrescriptionParser.parse('Furosemide 40mg 1 tab every other day');
      expect(r.days, ['Mon', 'Wed', 'Fri', 'Sun']);
      expect(r.note, contains('Every other day'));
    });

    test('daily = every day, and the date line does not add a day', () {
      final r = PrescriptionParser.parse('Date: Mon, Oct 5\nLosartan 50mg 1 tab once daily');
      expect(r.days, kDaysOfWeek);
      expect(r.foundDays, isTrue);
    });
  });

  group('times', () {
    test('8am and 8pm, 8 a.m. style', () {
      expect(times(PrescriptionParser.parse('1 tab at 8am and 8pm')), ['8:00 AM', '8:00 PM']);
      expect(times(PrescriptionParser.parse('1 tab at 7 a.m.')), ['7:00 AM']);
      expect(times(PrescriptionParser.parse('1 tab at 8:30PM')), ['8:30 PM']);
    });

    test('24-hour times', () {
      expect(times(PrescriptionParser.parse('1 tab at 08:00 and 20:00')), ['8:00 AM', '8:00 PM']);
    });

    test('1-0-1 = morning and night', () {
      expect(times(PrescriptionParser.parse('Amlodipine 5mg 1-0-1')), ['8:00 AM', '8:00 PM']);
    });

    test('morning and evening with twice a day', () {
      expect(times(PrescriptionParser.parse('1 tab twice a day, morning and evening')),
          ['8:00 AM', '7:00 PM']);
    });

    test('once a day after lunch', () {
      expect(times(PrescriptionParser.parse('1 tab once a day after lunch')), ['12:00 PM']);
    });

    test('Tagalog: tatlong beses / bago matulog', () {
      expect(times(PrescriptionParser.parse('1 tableta tatlong beses sa isang araw')).length, 3);
      expect(times(PrescriptionParser.parse('1 tableta bago matulog')), ['9:00 PM']);
    });

    test('b.i.d. with dots, and "x 2 weeks" is not twice a day', () {
      expect(times(PrescriptionParser.parse('1 cap b.i.d.')), ['8:00 AM', '8:00 PM']);
      expect(times(PrescriptionParser.parse('1 cap once daily x 2 weeks')), ['8:00 AM']);
    });

    test('duration and as-needed notes', () {
      final r = PrescriptionParser.parse('Amoxicillin 500mg 1 cap 3x a day for 7 days');
      expect(r.note, contains('Take for 7 days'));
      expect(PrescriptionParser.parse('Paracetamol 500mg 1 tab every 4 hours PRN').note,
          contains('as needed'));
    });
  });

  group('dosage', () {
    test('half and fractions', () {
      expect(PrescriptionParser.parse('Losartan 50mg\nTake 1/2 tab daily').dosage, '1/2 tablet (50 mg)');
      expect(PrescriptionParser.parse('Take ½ tablet daily').dosage, '1/2 tablet');
      expect(PrescriptionParser.parse('Take 1 1/2 tabs daily').dosage, '1 1/2 tablets');
    });

    test('syrup: strength per 5 ml and the ml dose', () {
      final r = PrescriptionParser.parse('Ambroxol 15mg/5ml syrup\nTake 5 ml 3x a day');
      expect(r.dosage, '5 ml (15 mg/5 ml)');
    });

    test('puffs, drops, capsules', () {
      expect(PrescriptionParser.parse('Salbutamol inhaler 2 puffs every 6 hours').dosage, '2 puffs');
      expect(PrescriptionParser.parse('Eye drops: instill 2 gtts twice daily').dosage, '2 drops');
      expect(PrescriptionParser.parse('Omeprazole 20mg 1 cap OD').dosage, '1 capsule (20 mg)');
    });
  });
}

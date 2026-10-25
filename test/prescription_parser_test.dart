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
    expect(r.dosage, 'one tablet (50 mg)');
    expect(times(r), ['8:00 AM']);
  });

  test('Metformin, BID, ignores pill count', () {
    final r = PrescriptionParser.parse('METFORMIN 500 MG\nTake 1 tab BID after meals\n#60 tablets');
    expect(r.name, 'Metformin');
    expect(r.dosage, '1 tab (500 mg)');
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
}

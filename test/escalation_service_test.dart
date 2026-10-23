// Missed-Dose Safety Escalation: checks the follow-ups, auto-missed,
// check-in, and caregiver alerts, with notifications/Firebase faked out.
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp4/escalation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeEffects extends EscalationEffects {
  final logs = <Map<String, Object?>>[];
  final alerts = <Map<String, Object?>>[];
  final cancelled = <int>[];
  final shown = <int>[];
  final scheduled = <Map<String, Object?>>[];

  @override
  Future<void> logIntake(String date, String medicine, String time, String status, {bool auto = false}) async =>
      logs.add({'date': date, 'medicine': medicine, 'time': time, 'status': status, 'auto': auto});

  @override
  Future<void> alert(String type, String message, {String severity = 'high', String? medicine}) async =>
      alerts.add({'type': type, 'message': message, 'severity': severity, 'medicine': medicine});

  @override
  Future<void> cancelNotification(int id) async => cancelled.add(id);

  @override
  Future<void> showNotification(int id, String title, String body, String payload) async => shown.add(id);

  @override
  Future<void> scheduleNotification(int id, String title, String body, DateTime when, String payload) async =>
      scheduled.add({'id': id, 'title': title, 'when': when});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final svc = EscalationService();
  final due = DateTime(2026, 10, 23, 8, 0);
  late FakeEffects fx;

  PendingDose dose(String name) =>
      PendingDose(medicine: name, dosage: '1 tablet', slot: 'A', date: '2026-10-23', time: '8:00 AM', due: due);
  DateTime after(int minutes) => due.add(Duration(minutes: minutes));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fx = FakeEffects();
    svc.effects = fx;
  });

  test('reminder schedules follow-ups at +10 and +20 minutes, no duplicates', () async {
    await svc.startTracking([dose('Losartan')], '{}');
    await svc.startTracking([dose('Losartan')], '{}'); // same dose again
    expect((await svc.pendingDoses()).length, 1);
    expect(fx.scheduled.map((s) => s['when']), [after(10), after(20)]);
  });

  test('tapping Yes logs on time, cancels follow-ups, no caregiver alert', () async {
    final d = dose('Losartan');
    await svc.startTracking([d], '{}');
    await svc.resolve(medicine: 'Losartan', date: d.date, time: d.time, taken: true);
    expect(fx.logs.single['status'], 'on_time');
    expect(fx.cancelled, containsAll([EscalationService.followUpId(d, 1), EscalationService.followUpId(d, 2)]));
    expect(await svc.pendingDoses(), isEmpty);
    expect(await svc.missStreak(), 0);
    expect(fx.alerts.where((a) => a['type'] != 'check_in_ok'), isEmpty);
  });

  test('tapping No logs missed and sends a "skipped" alert', () async {
    final d = dose('Losartan');
    await svc.startTracking([d], '{}');
    await svc.resolve(medicine: 'Losartan', date: d.date, time: d.time, taken: false);
    expect(fx.logs.single['status'], 'missed');
    expect(fx.alerts.single['type'], 'skipped');
    expect(await svc.missStreak(), 1);
  });

  test('no answer: nothing at 29 min, auto-missed + caregiver alert after 30 min, only once', () async {
    await svc.startTracking([dose('Losartan')], '{}');

    var r = await svc.processOverdue(now: after(29));
    expect(r.autoMissed, isEmpty);
    expect(fx.logs, isEmpty);

    r = await svc.processOverdue(now: after(31));
    expect(r.autoMissed.single.medicine, 'Losartan');
    expect(fx.logs.single['status'], 'missed');
    expect(fx.logs.single['auto'], isTrue);
    expect(fx.alerts.single['type'], 'missed_dose');
    expect(r.missStreak, 1);
    expect(r.needsCheckIn, isFalse);
    expect(await svc.pendingDoses(), isEmpty);

    await svc.processOverdue(now: after(45)); // running again must not double-log
    expect(fx.logs.length, 1);
  });

  test('2 misses in a row: "Are you okay?" check-in, then caregiver alert after 15 min (once)', () async {
    await svc.startTracking([dose('Losartan'), dose('Metformin')], '{}');

    var r = await svc.processOverdue(now: after(31));
    expect(r.missStreak, 2);
    expect(r.needsCheckIn, isTrue);
    expect(fx.shown, [EscalationService.checkInNotificationId]);

    r = await svc.processOverdue(now: after(40)); // 9 min later: still waiting
    expect(r.needsCheckIn, isTrue);
    expect(fx.shown.length, 1, reason: 'check-in notification shown only once');
    expect(fx.alerts.where((a) => a['type'] == 'no_response'), isEmpty);

    await svc.processOverdue(now: after(47)); // 16 min after check-in
    await svc.processOverdue(now: after(55));
    expect(fx.alerts.where((a) => a['type'] == 'no_response').length, 1);
  });

  test('"I\'m okay" resets the streak and tells the caregiver', () async {
    await svc.startTracking([dose('A'), dose('B')], '{}');
    await svc.processOverdue(now: after(31));
    await svc.confirmOkay();
    expect(await svc.missStreak(), 0);
    expect(fx.alerts.last['type'], 'check_in_ok');
    expect(fx.cancelled, contains(EscalationService.checkInNotificationId));

    final r = await svc.processOverdue(now: after(60));
    expect(r.needsCheckIn, isFalse);
  });

  test('"I need help" sends a high-priority help alert', () async {
    await svc.startTracking([dose('A'), dose('B')], '{}');
    await svc.processOverdue(now: after(31));
    await svc.requestHelp();
    expect(fx.alerts.last['type'], 'help_requested');
    expect(fx.alerts.last['severity'], 'high');
    expect(await svc.missStreak(), 0);
  });

  test('taking a dose after a miss resets the streak', () async {
    await svc.startTracking([dose('A')], '{}');
    await svc.processOverdue(now: after(31));
    expect(await svc.missStreak(), 1);
    await svc.resolve(medicine: 'B', date: '2026-10-23', time: '2:00 PM', taken: true);
    expect(await svc.missStreak(), 0);
  });
}

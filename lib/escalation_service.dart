import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_service.dart';
import 'time_utils.dart';

/// One dose that was announced but not yet confirmed.
class PendingDose {
  final String medicine;
  final String dosage;
  final String slot;
  final String date; // yyyy-MM-dd
  final String time; // "8:00 AM", same text the History tab uses
  final DateTime due;

  PendingDose({
    required this.medicine,
    required this.dosage,
    required this.slot,
    required this.date,
    required this.time,
    required this.due,
  });

  String get key => '$medicine|$date|$time';

  Map<String, dynamic> toJson() => {
        'medicine': medicine,
        'dosage': dosage,
        'slot': slot,
        'date': date,
        'time': time,
        'due': due.millisecondsSinceEpoch,
      };

  factory PendingDose.fromJson(Map<String, dynamic> j) => PendingDose(
        medicine: j['medicine'] as String,
        dosage: (j['dosage'] ?? '') as String,
        slot: (j['slot'] ?? '') as String,
        date: j['date'] as String,
        time: j['time'] as String,
        due: DateTime.fromMillisecondsSinceEpoch(j['due'] as int),
      );
}

/// Side effects of the escalation logic (notifications + Firebase).
/// Kept in one place so tests can swap them for fakes.
class EscalationEffects {
  Future<void> logIntake(String date, String medicine, String time, String status, {bool auto = false}) =>
      EscalationService.logIntake(date: date, medicine: medicine, time: time, status: status, auto: auto);

  Future<void> alert(String type, String message, {String severity = 'high', String? medicine}) =>
      EscalationService.addCaregiverAlert(type: type, message: message, severity: severity, medicine: medicine);

  Future<void> cancelNotification(int id) => NotificationService().cancelNotification(id: id);

  Future<void> showNotification(int id, String title, String body, String payload) =>
      NotificationService().showNotification(id: id, title: title, body: body, payload: payload);

  Future<void> scheduleNotification(int id, String title, String body, DateTime when, String payload) =>
      NotificationService().scheduleOneTimeNotification(id: id, title: title, body: body, when: when, payload: payload);
}

class EscalationCheck {
  final List<PendingDose> autoMissed;
  final bool needsCheckIn;
  final int missStreak;
  const EscalationCheck(this.autoMissed, this.needsCheckIn, this.missStreak);
}

/// Missed-Dose Safety Escalation.
///
/// Level 1: the normal reminder at the scheduled time.
/// Level 2: follow-up reminders 10 and 20 minutes later if not confirmed.
/// Level 3: after 30 minutes the dose is logged as missed and the caregiver is alerted.
/// Level 4: after 2 missed doses in a row, an "Are you okay?" check-in appears;
///          no answer within 15 minutes alerts the caregiver again.
class EscalationService {
  static final EscalationService _instance = EscalationService._internal();
  factory EscalationService() => _instance;
  EscalationService._internal();

  /// Replaceable in tests.
  EscalationEffects effects = EscalationEffects();

  static const Duration followUp1 = Duration(minutes: 10);
  static const Duration followUp2 = Duration(minutes: 20);
  static const Duration missedAfter = Duration(minutes: 30);
  static const int checkInAfterMisses = 2;
  static const Duration checkInTimeout = Duration(minutes: 15);

  static const String _pendingKey = 'escalation_pending';
  static const String _streakKey = 'escalation_miss_streak';
  static const String _checkInSinceKey = 'escalation_checkin_since';
  static const String _checkInAlertedKey = 'escalation_checkin_alerted';
  static const int checkInNotificationId = 424242;

  // ---------- storage ----------
  List<PendingDose> _load(SharedPreferences store) {
    final raw = store.getString(_pendingKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => PendingDose.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(SharedPreferences store, List<PendingDose> list) async {
    await store.setString(_pendingKey, jsonEncode(list.map((p) => p.toJson()).toList()));
  }

  static int followUpId(PendingDose d, int level) => stableId('${d.key}#$level');

  Future<void> _cancelFollowUps(PendingDose d) async {
    await effects.cancelNotification(followUpId(d, 1));
    await effects.cancelNotification(followUpId(d, 2));
  }

  Future<List<PendingDose>> pendingDoses() async => _load(await SharedPreferences.getInstance());

  // ---------- shared Firestore writes ----------
  static Future<void> logIntake({
    required String date,
    required String medicine,
    required String time,
    required String status, // 'on_time' | 'missed'
    bool auto = false,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('logs')
        .doc(date)
        .set({
      'intakes': FieldValue.arrayUnion([
        {
          'medicine': medicine,
          'time': time,
          'status': status,
          if (auto) 'auto': true,
        }
      ])
    }, SetOptions(merge: true));
  }

  /// Writes an alert that linked caregivers see in Caregiver Companion Mode.
  static Future<void> addCaregiverAlert({
    required String type,
    required String message,
    String severity = 'high',
    String? medicine,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('alerts')
        .add({
      'type': type,
      'message': message,
      'severity': severity,
      'medicine': medicine,
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtMs': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // ---------- public API ----------

  /// Call when a reminder fires. Schedules the follow-up reminders.
  Future<void> startTracking(List<PendingDose> doses, String payload) async {
    final store = await SharedPreferences.getInstance();
    final pending = _load(store);
    for (final d in doses) {
      if (pending.any((p) => p.key == d.key)) continue;
      pending.add(d);
      await effects.scheduleNotification(
        followUpId(d, 1),
        'Reminder: ${d.medicine} not confirmed',
        "You haven't confirmed ${d.medicine} (${d.time}) yet. Please take it now.",
        d.due.add(followUp1),
        payload,
      );
      await effects.scheduleNotification(
        followUpId(d, 2),
        'Last reminder: ${d.medicine}',
        'Confirm within 10 minutes or it will be marked as missed and your caregiver will be alerted.',
        d.due.add(followUp2),
        payload,
      );
    }
    await _save(store, pending);
  }

  /// Call when the user answers the Yes/No confirmation.
  Future<void> resolve({
    required String medicine,
    required String date,
    required String time,
    required bool taken,
  }) async {
    final store = await SharedPreferences.getInstance();
    final pending = _load(store);
    final matches = pending.where((p) => p.medicine == medicine && p.date == date && p.time == time).toList();
    for (final m in matches) {
      await _cancelFollowUps(m);
    }
    pending.removeWhere((p) => matches.any((m) => m.key == p.key));
    await _save(store, pending);

    await effects.logIntake(date, medicine, time, taken ? 'on_time' : 'missed');

    if (taken) {
      await _clearCheckIn(store);
      await store.setInt(_streakKey, 0);
    } else {
      await store.setInt(_streakKey, (store.getInt(_streakKey) ?? 0) + 1);
      await effects.alert(
        'skipped',
        'Skipped $medicine due at $time (tapped "No").',
        severity: 'medium',
        medicine: medicine,
      );
    }
  }

  /// Run every minute and on app start. Marks overdue doses as missed,
  /// alerts caregivers, and decides if the "Are you okay?" check-in is needed.
  Future<EscalationCheck> processOverdue({DateTime? now}) async {
    final DateTime t = now ?? DateTime.now();
    final store = await SharedPreferences.getInstance();
    final pending = _load(store);
    final overdue = pending.where((p) => t.isAfter(p.due.add(missedAfter))).toList();
    int streak = store.getInt(_streakKey) ?? 0;

    for (final p in overdue) {
      await _cancelFollowUps(p);
      streak++;
      try {
        await effects.logIntake(p.date, p.medicine, p.time, 'missed', auto: true);
        await effects.alert(
          'missed_dose',
          'Missed ${p.medicine}${p.dosage.isNotEmpty ? ' (${p.dosage})' : ''} due at ${p.time}. '
              'No confirmation after ${missedAfter.inMinutes} minutes.',
          medicine: p.medicine,
        );
      } catch (_) {}
    }
    if (overdue.isNotEmpty) {
      pending.removeWhere((p) => overdue.any((o) => o.key == p.key));
      await _save(store, pending);
      await store.setInt(_streakKey, streak);
    }

    bool needsCheckIn = false;
    if (streak >= checkInAfterMisses) {
      needsCheckIn = true;
      final since = store.getInt(_checkInSinceKey);
      if (since == null) {
        await store.setInt(_checkInSinceKey, t.millisecondsSinceEpoch);
        await store.setBool(_checkInAlertedKey, false);
        await effects.showNotification(
          checkInNotificationId,
          'PillPal check-in: are you okay?',
          'You missed $streak doses in a row. Tap to let us know you are okay.',
          jsonEncode({'type': 'check_in'}),
        );
      } else {
        final alerted = store.getBool(_checkInAlertedKey) ?? false;
        final waited = t.difference(DateTime.fromMillisecondsSinceEpoch(since));
        if (!alerted && waited >= checkInTimeout) {
          await store.setBool(_checkInAlertedKey, true);
          try {
            await effects.alert(
              'no_response',
              'Missed $streak doses in a row and did not answer the "Are you okay?" '
                  'check-in for ${checkInTimeout.inMinutes} minutes. Please check on them.',
            );
          } catch (_) {}
        }
      }
    }

    return EscalationCheck(overdue, needsCheckIn, streak);
  }

  Future<int> missStreak() async {
    final store = await SharedPreferences.getInstance();
    return store.getInt(_streakKey) ?? 0;
  }

  Future<void> confirmOkay() async {
    final store = await SharedPreferences.getInstance();
    final hadCheckIn = store.getInt(_checkInSinceKey) != null;
    await _clearCheckIn(store);
    await store.setInt(_streakKey, 0);
    if (hadCheckIn) {
      try {
        await effects.alert(
          'check_in_ok',
          'Answered the check-in: "I\'m okay".',
          severity: 'info',
        );
      } catch (_) {}
    }
  }

  Future<void> requestHelp() async {
    final store = await SharedPreferences.getInstance();
    await _clearCheckIn(store);
    await store.setInt(_streakKey, 0);
    await effects.alert(
      'help_requested',
      'Asked for help from the PillPal check-in. Please contact them now.',
    );
  }

  Future<void> _clearCheckIn(SharedPreferences store) async {
    await store.remove(_checkInSinceKey);
    await store.remove(_checkInAlertedKey);
    await effects.cancelNotification(checkInNotificationId);
  }
}

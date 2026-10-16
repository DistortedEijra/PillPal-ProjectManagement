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

  static const Duration followUp1 = Duration(minutes: 10);
  static const Duration followUp2 = Duration(minutes: 20);
  static const Duration missedAfter = Duration(minutes: 30);
  static const int checkInAfterMisses = 2;
  static const Duration checkInTimeout = Duration(minutes: 15);

  static const String _pendingKey = 'escalation_pending';
  static const String _streakKey = 'escalation_miss_streak';
  static const String _checkInSinceKey = 'escalation_checkin_since';
  static const String _checkInAlertedKey = 'escalation_checkin_alerted';
  static const int _checkInNotificationId = 424242;

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

  int _followUpId(PendingDose d, int level) => stableId('${d.key}#$level');

  Future<void> _cancelFollowUps(PendingDose d) async {
    await NotificationService().cancelNotification(id: _followUpId(d, 1));
    await NotificationService().cancelNotification(id: _followUpId(d, 2));
  }

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
      await NotificationService().scheduleOneTimeNotification(
        id: _followUpId(d, 1),
        title: 'Reminder: ${d.medicine} not confirmed',
        body: "You haven't confirmed ${d.medicine} (${d.time}) yet. Please take it now.",
        when: d.due.add(followUp1),
        payload: payload,
      );
      await NotificationService().scheduleOneTimeNotification(
        id: _followUpId(d, 2),
        title: 'Last reminder: ${d.medicine}',
        body: 'Confirm within 10 minutes or it will be marked as missed and your caregiver will be alerted.',
        when: d.due.add(followUp2),
        payload: payload,
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

    await logIntake(date: date, medicine: medicine, time: time, status: taken ? 'on_time' : 'missed');

    if (taken) {
      await _clearCheckIn(store);
      await store.setInt(_streakKey, 0);
    } else {
      await store.setInt(_streakKey, (store.getInt(_streakKey) ?? 0) + 1);
      await addCaregiverAlert(
        type: 'skipped',
        severity: 'medium',
        medicine: medicine,
        message: 'Skipped $medicine due at $time (tapped "No").',
      );
    }
  }

  /// Run every minute and on app start. Marks overdue doses as missed,
  /// alerts caregivers, and decides if the "Are you okay?" check-in is needed.
  Future<EscalationCheck> processOverdue() async {
    final store = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final pending = _load(store);
    final overdue = pending.where((p) => now.isAfter(p.due.add(missedAfter))).toList();
    int streak = store.getInt(_streakKey) ?? 0;

    for (final p in overdue) {
      await _cancelFollowUps(p);
      streak++;
      try {
        await logIntake(date: p.date, medicine: p.medicine, time: p.time, status: 'missed', auto: true);
        await addCaregiverAlert(
          type: 'missed_dose',
          medicine: p.medicine,
          message: 'Missed ${p.medicine}${p.dosage.isNotEmpty ? ' (${p.dosage})' : ''} due at ${p.time}. '
              'No confirmation after ${missedAfter.inMinutes} minutes.',
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
        await store.setInt(_checkInSinceKey, now.millisecondsSinceEpoch);
        await store.setBool(_checkInAlertedKey, false);
        await NotificationService().showNotification(
          id: _checkInNotificationId,
          title: 'PillPal check-in: are you okay?',
          body: 'You missed $streak doses in a row. Tap to let us know you are okay.',
          payload: jsonEncode({'type': 'check_in'}),
        );
      } else {
        final alerted = store.getBool(_checkInAlertedKey) ?? false;
        final waited = now.difference(DateTime.fromMillisecondsSinceEpoch(since));
        if (!alerted && waited >= checkInTimeout) {
          await store.setBool(_checkInAlertedKey, true);
          try {
            await addCaregiverAlert(
              type: 'no_response',
              message: 'Missed $streak doses in a row and did not answer the "Are you okay?" '
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
        await addCaregiverAlert(
          type: 'check_in_ok',
          severity: 'info',
          message: 'Answered the check-in: "I\'m okay".',
        );
      } catch (_) {}
    }
  }

  Future<void> requestHelp() async {
    final store = await SharedPreferences.getInstance();
    await _clearCheckIn(store);
    await store.setInt(_streakKey, 0);
    await addCaregiverAlert(
      type: 'help_requested',
      message: 'Asked for help from the PillPal check-in. Please contact them now.',
    );
  }

  Future<void> _clearCheckIn(SharedPreferences store) async {
    await store.remove(_checkInSinceKey);
    await store.remove(_checkInAlertedKey);
    await NotificationService().cancelNotification(id: _checkInNotificationId);
  }
}

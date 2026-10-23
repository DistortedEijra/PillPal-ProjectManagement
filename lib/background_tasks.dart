import 'dart:io';
import 'dart:ui';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';

import 'escalation_service.dart';
import 'notification_service.dart';
import 'time_utils.dart';

/// Background work that must run even when PillPal is closed:
/// - ~31 min after each reminder: mark unanswered doses as missed, alert the
///   caregiver, and show the "Are you okay?" check-in after 2 misses in a row.
/// - 15 min after the check-in: alert the caregiver if it's still unanswered.
///
/// Uses android_alarm_manager_plus, which wakes a small background copy of the
/// app. On Xiaomi phones "Autostart" must be ON for this to run.
class BackgroundTasks {
  static const int checkInTimeoutAlarmId = 424243;

  static Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    await AndroidAlarmManager.initialize();
  }

  /// One alarm per reminder slot. [params] holds weekday/hour/minute of the
  /// check time, the reminder's time text, and the medicines due.
  static Future<bool> scheduleDueCheck({
    required int id,
    required DateTime at,
    required Map<String, dynamic> params,
  }) async {
    if (!Platform.isAndroid) return false;
    return AndroidAlarmManager.oneShotAt(
      at,
      id,
      missedDoseCheckCallback,
      exact: true,
      wakeup: true,
      allowWhileIdle: true,
      rescheduleOnReboot: true,
      params: params,
    );
  }

  static Future<void> cancel(int id) async {
    if (!Platform.isAndroid) return;
    await AndroidAlarmManager.cancel(id);
  }

  static Future<void> scheduleCheckInTimeout(DateTime when) async {
    if (!Platform.isAndroid) return;
    await AndroidAlarmManager.oneShotAt(
      when,
      checkInTimeoutAlarmId,
      checkInTimeoutCallback,
      exact: true,
      wakeup: true,
      allowWhileIdle: true,
      rescheduleOnReboot: true,
    );
  }

  static Future<void> cancelCheckInTimeout() => cancel(checkInTimeoutAlarmId);
}

/// Sets up Firebase and notifications inside the background copy of the app.
/// Returns false if nobody is logged in.
Future<bool> _prepareBackground() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  User? user = FirebaseAuth.instance.currentUser;
  user ??= await FirebaseAuth.instance
      .authStateChanges()
      .first
      .timeout(const Duration(seconds: 10), onTimeout: () => null);
  if (user == null) return false;
  await NotificationService().init();
  return true;
}

List<Map<String, String>> _medsFromParams(Map<String, dynamic> params) {
  final raw = (params['meds'] as List?) ?? const [];
  return raw
      .whereType<Map>()
      .map((m) => m.map((k, v) => MapEntry('$k', '${v ?? ''}')))
      .toList();
}

@pragma('vm:entry-point')
Future<void> missedDoseCheckCallback(int id, Map<String, dynamic> params) async {
  try {
    if (!await _prepareBackground()) return; // logged out: stop re-arming
    final now = DateTime.now();
    final due = now.subtract(EscalationService.missedAfter);
    await EscalationService().handleDueCheck(
      date: dateKey(due),
      time: (params['time'] ?? '') as String,
      meds: _medsFromParams(params),
      now: now,
    );

    // Re-arm for the same day and time next week.
    final weekday = (params['weekday'] as num?)?.toInt();
    final hour = (params['hour'] as num?)?.toInt();
    final minute = (params['minute'] as num?)?.toInt();
    if (weekday != null && hour != null && minute != null) {
      await BackgroundTasks.scheduleDueCheck(
        id: id,
        at: nextWeeklyAt(weekday, hour, minute, from: now.add(const Duration(minutes: 1))),
        params: params,
      );
    }
  } catch (e) {
    debugPrint('PillPal background check failed: $e');
  }
}

@pragma('vm:entry-point')
Future<void> checkInTimeoutCallback(int id, Map<String, dynamic> params) async {
  try {
    if (!await _prepareBackground()) return;
    await EscalationService().handleCheckInTimeout();
  } catch (e) {
    debugPrint('PillPal check-in timeout failed: $e');
  }
}

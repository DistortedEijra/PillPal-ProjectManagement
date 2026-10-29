import 'dart:async';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart' as prefs;
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class NotificationService {
  // Singleton pattern
  static final NotificationService _notificationService = NotificationService._internal();
  factory NotificationService() {
    return _notificationService;
  }
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
  FlutterLocalNotificationsPlugin();

  final StreamController<String?> tapPayloadController = StreamController<String?>.broadcast();

  // Payload of the notification that cold-started the app (read once by the dashboard).
  String? _launchPayload;
  void setLaunchPayload(String? payload) => _launchPayload = payload;
  String? takeLaunchPayload() {
    final p = _launchPayload;
    _launchPayload = null;
    return p;
  }

  static const String _logKeyPrefix = 'med_log_';
  static const String _weeklyLogKeyPrefix = 'med_weekly_';
  static const String _medicationCreatedKeyPrefix = 'med_created_';

  // Use a dedicated channel id to ensure custom sound applies (Android channels are immutable once created)
  static const String _channelId = 'medicine_reminder_channel_fah';
  static const String _channelName = 'Medicine Reminders';
  static const String _channelDescription = 'Channel for medicine reminder notifications';

  Future<void> init({
    void Function(NotificationResponse)? onDidReceiveBackgroundNotificationResponse,
  }) async {
    print('DEBUG: NotificationService.init() called');

    // Get the native timezone
    final TimezoneInfo timezoneInfo = await FlutterTimezone.getLocalTimezone();
    final String timeZoneName = timezoneInfo.identifier;

    print('DEBUG: Detected timezone: $timeZoneName');

    // Initialize timezone database
    tz.initializeTimeZones();
    print('DEBUG: Timezone data initialized');

    // Set the local location
    try {
      tz.setLocalLocation(tz.getLocation(timeZoneName));
      print('DEBUG: Timezone location set to $timeZoneName');
    } catch (e) {
      print("ERROR setting timezone: $e. The name '$timeZoneName' might be invalid.");
    }

    // Android initialization
    const AndroidInitializationSettings initializationSettingsAndroid =
    AndroidInitializationSettings('@drawable/icon');

    // iOS initialization
    const DarwinInitializationSettings initializationSettingsIOS =
    DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (response) {
        print('DEBUG: Notification tapped: ${response.payload}');
        tapPayloadController.add(response.payload);
      },
      onDidReceiveBackgroundNotificationResponse: onDidReceiveBackgroundNotificationResponse,
    );
    print('DEBUG: flutterLocalNotificationsPlugin initialized');

    // Create Android channel explicitly
    final androidPlugin = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDescription,
          importance: Importance.max,
          playSound: true,
          sound: RawResourceAndroidNotificationSound('fahh_effect'),
          enableLights: true,
        ),
      );
      print('DEBUG: Android channel created');
    }
  }

  Future<void> requestPermissions() async {
    print('DEBUG: requestPermissions() called');

    if (Platform.isAndroid) {
      // Request notification permission (Android 13+)
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
        print('DEBUG: Requested notification permission');
        final AndroidIntent fsiIntent = AndroidIntent(
          action: 'android.settings.MANAGE_APP_USE_FULL_SCREEN_INTENT',
          data: Uri(scheme: 'package', path: 'com.example.myapp4').toString(),
        );
        await fsiIntent.launch();
        print('DEBUG: Opened full screen intent settings');

      }

      // Check and request exact alarm permission (Android 12+)
      final alarmStatus = await Permission.scheduleExactAlarm.status;
      print('DEBUG: Exact alarm status: $alarmStatus');
      if (!alarmStatus.isGranted) {
        const AndroidIntent intent = AndroidIntent(
          action: 'android.settings.REQUEST_SCHEDULE_EXACT_ALARM',
        );
        await intent.launch();
        print('DEBUG: Opened exact alarm settings');
        // Wait and recheck (optional, for logging)
        await Future.delayed(const Duration(seconds: 5));
        final newStatus = await Permission.scheduleExactAlarm.status;
        print('DEBUG: New exact alarm status after settings: $newStatus');
      } else {
        print('DEBUG: Exact alarm permission already granted');
      }
    }

    // Existing iOS request (unchanged)
    final iosPlugin = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    if (iosPlugin != null) {
      await iosPlugin.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    print('DEBUG: Showing immediate notification with id: $id, title: $title');
    await flutterLocalNotificationsPlugin.show(
      id,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.max,
          priority: Priority.high,
          icon: '@drawable/icon',
          playSound: true,
          sound: RawResourceAndroidNotificationSound('fahh_effect'),
          fullScreenIntent: true,
          enableLights: true,
          groupKey: 'medicine_group',
        ),
        iOS: DarwinNotificationDetails(
          presentSound: true,
        ),
      ),
      payload: payload,
    );
    print('DEBUG: Immediate notification shown.');
  }

  // scheduleWeeklyNotification
  Future<void> scheduleWeeklyNotification({
    required int id,
    required String title,
    required String body,
    required int day, // Monday = 1, ..., Sunday = 7
    required TimeOfDay time,
    String? payload,
    DateTime? notBefore, // skip occurrences up to this moment (e.g. "already answered today")
  }) async {
    print('DEBUG: Adding reminder for "$title" with time $time.');
    print('DEBUG: scheduleWeeklyNotification() called with id: $id, title: $title, day: $day, time: $time');
    tz.TZDateTime scheduledTime = _nextInstanceOfDayAndTime(day, time);
    if (notBefore != null) {
      final limit = tz.TZDateTime.from(notBefore, tz.local);
      while (!scheduledTime.isAfter(limit)) {
        scheduledTime = scheduledTime.add(const Duration(days: 7));
      }
    }
    print('DEBUG: Calculated scheduled time: $scheduledTime');

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.max,
        priority: Priority.high,
        icon: '@drawable/icon',
        playSound: true,
        sound: RawResourceAndroidNotificationSound('fahh_effect'),
        fullScreenIntent: true,
        enableLights: true,
        groupKey: 'medicine_group',
      ),
      iOS: DarwinNotificationDetails(
        presentSound: true,
      ),
    );

    try {
      await flutterLocalNotificationsPlugin.zonedSchedule(
        id,
        title,
        body,
        scheduledTime,
        details,
        payload: payload,
        androidScheduleMode: AndroidScheduleMode.alarmClock,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
      );
    } catch (e) {
      // Exact alarms not allowed on this phone: fall back to an inexact alarm.
      print('DEBUG: exact weekly alarm failed ($e), using inexact');
      await flutterLocalNotificationsPlugin.zonedSchedule(
        id,
        title,
        body,
        scheduledTime,
        details,
        payload: payload,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
      );
    }
    print('DEBUG: Notification has been scheduled.');
  }

  // One-time notification at an exact moment (used for missed-dose follow-ups).
  Future<void> scheduleOneTimeNotification({
    required int id,
    required String title,
    required String body,
    required DateTime when,
    String? payload,
  }) async {
    final tz.TZDateTime scheduled = tz.TZDateTime.from(when, tz.local);
    if (scheduled.isBefore(tz.TZDateTime.now(tz.local))) return;

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.max,
        priority: Priority.high,
        icon: '@drawable/icon',
        playSound: true,
        sound: RawResourceAndroidNotificationSound('fahh_effect'),
        fullScreenIntent: true,
        enableLights: true,
        groupKey: 'medicine_group',
      ),
      iOS: DarwinNotificationDetails(presentSound: true),
    );

    try {
      await flutterLocalNotificationsPlugin.zonedSchedule(
        id,
        title,
        body,
        scheduled,
        details,
        payload: payload,
        androidScheduleMode: AndroidScheduleMode.alarmClock,
      );
    } catch (e) {
      // Exact alarms not allowed on this phone: fall back to an inexact alarm.
      print('DEBUG: exact follow-up failed ($e), using inexact');
      await flutterLocalNotificationsPlugin.zonedSchedule(
        id,
        title,
        body,
        scheduled,
        details,
        payload: payload,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }

  tz.TZDateTime _nextInstanceOfDayAndTime(int day, TimeOfDay time) {
    print('DEBUG: _nextInstanceOfDayAndTime() called with day: $day, time: $time');
    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    print("DEBUG: Current datetime 'now' is: $now. Timezone: ${now.timeZoneName}");
    tz.TZDateTime scheduledDate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );
    print("DEBUG: Initial scheduledDate: $scheduledDate");

    while (scheduledDate.weekday != day) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }
    print("DEBUG: scheduledDate after weekday loop: $scheduledDate");

    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 7));
      print("DEBUG: scheduledDate is in the past, adding 7 days. New scheduledDate: $scheduledDate");
    }

    return scheduledDate;
  }

  // scheduleTestNotification
  Future<void> scheduleTestNotification() async {
    print('DEBUG: scheduleTestNotification() called.');
    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    final tz.TZDateTime scheduledTime = now.add(const Duration(seconds: 5));
    print('DEBUG: Scheduling a test notification for: $scheduledTime');

    await flutterLocalNotificationsPlugin.zonedSchedule(
      999,
      'Test Notification',
      'If you can see this, scheduling is working.',
      scheduledTime,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.max,
          priority: Priority.high,
          icon: '@drawable/icon',
          playSound: true,
          sound: RawResourceAndroidNotificationSound('fahh_effect'),
          fullScreenIntent: true,
          enableLights: true,
          groupKey: 'medicine_group',
        ),
        iOS: DarwinNotificationDetails(
          presentSound: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.alarmClock,
    );
    print('DEBUG: Test notification has been scheduled.');
  }

  /// True if a notification with [id] is on screen right now (Android).
  Future<bool> isShowing(int id) async {
    try {
      final android = flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return false;
      final active = await android.getActiveNotifications();
      return active.any((n) => n.id == id);
    } catch (e) {
      print('DEBUG: could not read active notifications: $e');
      return false;
    }
  }

  Future<void> cancelNotification({required int id}) async {
    await flutterLocalNotificationsPlugin.cancel(id);
    print('DEBUG: Canceled notification with id: $id');
  }

  // Bonus: Method to list pending notifications for debugging
  Future<void> listPendingNotifications() async {
    final pending = await flutterLocalNotificationsPlugin.pendingNotificationRequests();
    print('DEBUG: Pending notifications: ${pending.length}');
    for (var notif in pending) {
      print('ID: ${notif.id}, Title: ${notif.title}, Body: ${notif.body}');
    }
  }

  // Add tracking for medication status
  Future<void> logMedicationTaken({
    required int medicationId,
    required DateTime timestamp,
    required bool taken,
  }) async {
    final store = await prefs.SharedPreferences.getInstance();
    final key = '${_logKeyPrefix}${medicationId}_${_formatDate(timestamp)}';

    // Store the medication status
    await store.setBool(key, taken);

    // Update weekly statistics
    final weekKey = '${_weeklyLogKeyPrefix}${medicationId}_${_getWeekNumber(timestamp)}';
    final weeklyData = store.getStringList(weekKey) ?? [];
    weeklyData.add('${_formatDate(timestamp)}:${taken ? 1 : 0}');
    await store.setStringList(weekKey, weeklyData);

    print('DEBUG: Logged medication $medicationId as ${taken ? "taken" : "missed"} at $timestamp');
  }

  // Get daily medication history
  Future<List<MedicationLog>> getDailyLogs({
    required int medicationId,
    required DateTime date,
  }) async {
    final store = await prefs.SharedPreferences.getInstance();
    final key = '${_logKeyPrefix}${medicationId}_${_formatDate(date)}';

    final taken = store.getBool(key) ?? false;
    return [
      MedicationLog(
        medicationId: medicationId,
        timestamp: date,
        taken: taken,
      )
    ];
  }

  // Add method to store medication creation date
  Future<void> recordMedicationCreation({
    required int medicationId,
    DateTime? createdAt,
  }) async {
    final store = await prefs.SharedPreferences.getInstance();
    final key = '${_medicationCreatedKeyPrefix}$medicationId';
    final timestamp = (createdAt ?? DateTime.now()).millisecondsSinceEpoch;
    await store.setInt(key, timestamp);
  }

  // Get weekly medication history with creation date check
  Future<WeeklyMedicationSummary> getWeeklyLogs({
    required int medicationId,
    required DateTime weekStart,
  }) async {
    final store = await prefs.SharedPreferences.getInstance();
    
    // Get medication creation date
    final creationKey = '${_medicationCreatedKeyPrefix}$medicationId';
    final creationTimestamp = store.getInt(creationKey);
    if (creationTimestamp == null) {
      return WeeklyMedicationSummary(
        medicationId: medicationId,
        weekStart: weekStart,
        taken: 0,
        missed: 0,
      );
    }

    final creationDate = DateTime.fromMillisecondsSinceEpoch(creationTimestamp);
    final weekKey = '${_weeklyLogKeyPrefix}${medicationId}_${_getWeekNumber(weekStart)}';
    final weeklyData = store.getStringList(weekKey) ?? [];
    
    int taken = 0;
    int missed = 0;

    for (final entry in weeklyData) {
      final parts = entry.split(':');
      if (parts.length == 2) {
        final logDate = DateTime.parse(parts[0]);
        // Only count logs after medication creation date
        if (logDate.isAfter(creationDate)) {
          parts[1] == '1' ? taken++ : missed++;
        }
      }
    }

    return WeeklyMedicationSummary(
      medicationId: medicationId,
      weekStart: weekStart,
      taken: taken,
      missed: missed,
    );
  }

  // Helper methods
  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  int _getWeekNumber(DateTime date) {
    final firstDayOfYear = DateTime(date.year, 1, 1);
    final daysIntoYear = date.difference(firstDayOfYear).inDays;
    return (daysIntoYear / 7).floor() + 1;
  }

  void dispose() {
    tapPayloadController.close();
  }
}

// Data classes for medication logs
class MedicationLog {
  final int medicationId;
  final DateTime timestamp;
  final bool taken;

  MedicationLog({
    required this.medicationId,
    required this.timestamp,
    required this.taken,
  });
}

class WeeklyMedicationSummary {
  final int medicationId;
  final DateTime weekStart;
  final int taken;
  final int missed;

  WeeklyMedicationSummary({
    required this.medicationId,
    required this.weekStart,
    required this.taken,
    required this.missed,
  });

  double get adherenceRate =>
      taken + missed > 0 ? (taken / (taken + missed)) * 100 : 0;
}

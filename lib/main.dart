import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:myapp4/auth_wrapper.dart';
import 'notification_service.dart';
import 'bluetooth_service.dart';
import 'package:permission_handler/permission_handler.dart';

// Top-level function for handling background notification taps
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse notificationResponse) {
  print('Notification Tapped in background: ${notificationResponse.payload}');
  // Handle payload processing here if necessary
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize services
  final NotificationService notificationService = NotificationService();
  await notificationService.init(
    onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
  );

  await Firebase.initializeApp();

  await [
    Permission.bluetooth,
    Permission.bluetoothConnect,
    Permission.bluetoothScan,
  ].request();

  await notificationService.requestPermissions();

  // Check if the app was launched from a notification and send BT signal
  final NotificationAppLaunchDetails? notificationAppLaunchDetails =
      await notificationService.flutterLocalNotificationsPlugin
          .getNotificationAppLaunchDetails();

  await _processNotificationLaunch(notificationAppLaunchDetails);

  // Activate App Check
  await FirebaseAppCheck.instance.activate(
    // Use the debug provider in debug builds
    androidProvider: AndroidProvider.debug,
    appleProvider: AppleProvider.debug,
  );

  runApp(const ProgressReportApp());
}

Future<void> _processNotificationLaunch(
  NotificationAppLaunchDetails? details,
) async {
  if (!(details?.didNotificationLaunchApp ?? false)) {
    return;
  }

  final payload = details?.notificationResponse?.payload;
  if (payload == null || payload.isEmpty) {
    return;
  }

  print("App launched from notification with payload: $payload");

  final slots = _extractSlotsFromPayload(payload);
  if (slots.isEmpty) {
    print("No valid slots extracted from payload.");
    return;
  }

  for (final slot in slots) {
    print("Sending Bluetooth signal for slot: $slot");
    BluetoothService().sendSignal(slot);
  }
}

List<String> _extractSlotsFromPayload(String payload) {
  final Set<String> slots = {};

  try {
    final dynamic decoded = jsonDecode(payload);
    if (decoded is Map<String, dynamic>) {
      final medicines = decoded['medicines'];
      if (medicines is List) {
        for (final med in medicines) {
          if (med is Map<String, dynamic>) {
            final slot = med['slot'];
            if (slot is String &&
                slot.trim().isNotEmpty &&
                slot.toLowerCase() != 'null') {
              slots.add(slot.trim());
            }
          }
        }
      }
    }
  } catch (_) {
    // Fallback to legacy format: "slot:A,medicine:Aspirin"
    final parts = payload.split(',');
    for (var part in parts) {
      final keyValue = part.split(':');
      if (keyValue.length == 2 && keyValue[0].trim() == 'slot') {
        final slot = keyValue[1].trim();
        if (slot.isNotEmpty && slot.toLowerCase() != 'null') {
          slots.add(slot);
        }
      }
    }
  }

  return slots.toList();
}

class ProgressReportApp extends StatelessWidget {
  const ProgressReportApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PillPal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: const Color(0xFF116FA9),
        fontFamily: 'Roboto',
      ),
      // Set the AuthWrapper as the entry point
      home: const AuthWrapper(),
    );
  }
}

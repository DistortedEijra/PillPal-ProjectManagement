import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'notification_service.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'bluetooth_service.dart';
import 'debug_bluetooth_page.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import 'dart:developer';
import 'package:image_picker/image_picker.dart';
import 'scan_to_schedule.dart';
import 'scan_review_dialog.dart';
import 'escalation_service.dart';
import 'caregiver_service.dart';
import 'caregiver_page.dart';
import 'time_utils.dart';
import 'reminder_scheduler.dart';
import 'medicine_editor.dart';
import 'pillbox_sync.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  List<Map<String, dynamic>> medicines = [];
  List<Map<String, dynamic>> allMedicines = [];
  List<Map<String, String>> pillBoxAssignments = [];
  String activePage = "Dashboard";
  final List<String> daysOfWeek = const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  String? pairedDeviceName;
  String? givenName; // Firestore-stored user given name
  Timer? _scheduleTimer;
  // Minutes ("2026-10-24 8:0") whose dose was already sent to the box, so the
  // 5-second check fires each dose only once.
  final Set<String> _firedMinutes = {};
  int _timerTicks = 0;
  late StreamSubscription<bool> _connectionSubscription;
  late StreamSubscription<String> _dataSubscription;
  bool isPillBoxConnected = false;
  String historyMode = 'Daily'; // Added for history sub-modes
  late StreamSubscription<String?> _notificationTapSubscription;
  final CareListeners _careListeners = CareListeners();
  bool _checkInDialogOpen = false;
  bool _remindersScheduled = false; // true once real Android alarms are set
  // Live updates of the schedules, so edits made by a caregiver show up here
  // and the reminders are re-scheduled.
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _schedulesSub;
  // Only send the reminder list to the PillPalBox once both were loaded, so a
  // failed load never wipes the reminders saved in the box.
  bool _schedulesLoaded = false;
  bool _slotsLoaded = false;

  @override
  void initState() {
    super.initState();
    _initializeServices();
    _fetchUserData();
    _loadPairedDevice();
    _startScheduleTimer();
    _careListeners.start();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final launchPayload = NotificationService().takeLaunchPayload();
      if (launchPayload != null) _handleNotificationPayload(launchPayload);
      await _runEscalationCheck();
    });

    PillBoxSync.confirmReplace = _confirmReplaceBox;
    PillBoxSync.onKeptOtherList = (ownerName) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Kept ${ownerName.isEmpty ? 'the other' : "$ownerName's"} medicines in the PillPalBox. "
            'Your reminders still work on this phone.'),
      ));
    };

    _connectionSubscription = BluetoothService().isConnectedStream.listen((isConnected) {
      if (mounted) {
        setState(() {
          isPillBoxConnected = isConnected;
        });
      }
      // Each time the box connects: set its clock and send the reminder list.
      if (isConnected) {
        _syncPillBox();
      } else {
        PillBoxSync.resetConnection(); // ask again next time it connects
      }
    });

    _dataSubscription = BluetoothService().dataStream.listen((data) {
      if (mounted) {
        log("Received data from pillbox: $data");
        // Handle incoming data, e.g., lid open confirmation
      }
    });

    _notificationTapSubscription = NotificationService().tapPayloadController.stream.listen((payload) {
      if (payload != null && mounted) {
        _handleNotificationPayload(payload);
      }
    });

    // Initial connection attempt
    BluetoothService().connect();
  }

  Future<void> _initializeServices() async {
    await NotificationService().init();
  }

  @override
  void dispose() {
    _scheduleTimer?.cancel();
    _schedulesSub?.cancel();
    _connectionSubscription.cancel();
    _dataSubscription.cancel();
    _notificationTapSubscription.cancel();
    _careListeners.stop();
    BluetoothService().dispose();
    super.dispose();
  }

  void _startScheduleTimer() {
    // Check every 5 seconds so the box lights up within a few seconds of the
    // scheduled time (a 1-minute timer could be up to 59 s late, or skip a
    // minute). The missed-dose escalation check still runs about once a minute.
    _scheduleTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!mounted) return;
      _timerTicks++;
      _checkSchedules(runEscalation: _timerTicks % 12 == 0);
    });
  }

  void _checkSchedules({bool runEscalation = true}) {
    final now = DateTime.now();
    final String currentDay = daysOfWeek[now.weekday - 1];
    final TimeOfDay currentTime = TimeOfDay.fromDateTime(now);
    List<Map<String, dynamic>> dueMedicines = [];

    for (final med in medicines) {
      if (!runsOn(med['endDate'] as String?, now)) continue; // course finished
      final List<String> repeatDays = (med['repeatDays'] as List).cast<String>();
      final List<TimeOfDay> schedules = (med['schedules'] as List).cast<TimeOfDay>();

      if (repeatDays.contains(currentDay)) {
        for (final scheduleTime in schedules) {
          if (scheduleTime.hour == currentTime.hour && scheduleTime.minute == currentTime.minute) {
            dueMedicines.add(med);
            break; // Assume one schedule per med at a time for simplicity
          }
        }
      }
    }

    final minuteKey = '${dateKey(now)} ${now.hour}:${now.minute}';
    if (dueMedicines.isNotEmpty && _firedMinutes.add(minuteKey)) {
      _triggerAlarm(dueMedicines, now);
    }

    if (runEscalation) _runEscalationCheck();
  }

  // ---------- Missed-Dose Safety Escalation ----------
  Future<void> _runEscalationCheck() async {
    try {
      final result = await EscalationService().processOverdue();
      if (!mounted) return;
      if (result.autoMissed.isNotEmpty) {
        final names = result.autoMissed.map((d) => d.medicine).join(', ');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Marked as missed (no confirmation after 30 min): $names')),
        );
      }
      if (result.needsCheckIn) _showCheckInDialog(result.missStreak);
    } catch (e) {
      log('Escalation check failed: $e');
    }
  }

  void _handleNotificationPayload(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map && decoded['type'] == 'check_in') {
        EscalationService().missStreak().then(_showCheckInDialog);
        return;
      }
    } catch (_) {}
    _showConfirmationDialog(payload);
  }

  void _showCheckInDialog(int streak) {
    if (!mounted || _checkInDialogOpen) return;
    _checkInDialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Are you okay?'),
        content: Text(
          'You missed $streak dose(s) in a row.\n\n'
          "Tap \"I'm okay\" so we don't alert your caregiver. "
          'If you need help, tap "I need help" and your caregiver will be told right away.',
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              _checkInDialogOpen = false;
              try {
                await EscalationService().requestHelp();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Your caregiver has been alerted.')),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Could not alert caregiver: $e')),
                  );
                }
              }
            },
            child: const Text('I need help'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF116FA9),
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              _checkInDialogOpen = false;
              await EscalationService().confirmOkay();
            },
            child: const Text("I'm okay"),
          ),
        ],
      ),
    );
  }

  Future<void> _triggerAlarm(List<Map<String, dynamic>> dueMedicines, DateTime now) async {
    if (!mounted) return;

    final String scheduledTimeStr = formatTime(TimeOfDay.fromDateTime(now));
    final String dateStr = dateKey(now);

    // Trigger hardware signals first
    for (var med in dueMedicines) {
      final String medicineName = med['name'];
      final assignment = pillBoxAssignments.firstWhere(
        (assignment) => assignment['medicine'] == medicineName,
        orElse: () => <String, String>{},
      );

      if (assignment.isNotEmpty && assignment['slot'] != null) {
        String slot = (assignment['slot'] ?? '').toUpperCase();
        // Send as single-character blink command (A..F); slight spacing to avoid coalescing
        final success = await BluetoothService().sendSignal(slot);
        if (!success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to send signal to pillbox for $medicineName.')),
          );
        }
        await Future.delayed(const Duration(milliseconds: 80));
      }
    }

    // Now, create a single grouped notification
    final List<Map<String, String>> medicinesPayload = dueMedicines.map((med) {
      final assignment = pillBoxAssignments.firstWhere(
        (assignment) => assignment['medicine'] == med['name'],
        orElse: () => <String, String>{},
      );
      return {
        'name': med['name'] as String,
        'dosage': med['dosage'] as String,
        'slot': assignment.isNotEmpty ? ((assignment['slot'] ?? '').toString().toUpperCase()) : '',
      };
    }).toList();

    final String payload = jsonEncode({
      'medicines': medicinesPayload,
      'date': dateStr,
      'time': scheduledTimeStr,
    });

    final String notificationBody = dueMedicines.length > 1
        ? '${dueMedicines.length} medicines are due.'
        : 'Time to take your ${dueMedicines.first['name']}.';

    // Same id as the scheduled weekly alarm for this time, so the reminder
    // never shows twice.
    final int notificationId =
        reminderIdFor(now.weekday, TimeOfDay(hour: now.hour, minute: now.minute));

    // Normally the scheduled Android alarm shows this reminder. It can miss
    // (for example the time was changed seconds before, or the phone delayed
    // it), so give it a few seconds, and show it from here if it isn't there.
    var showHere = true;
    if (_remindersScheduled) {
      final wait = 8 - DateTime.now().second;
      if (wait > 0) await Future.delayed(Duration(seconds: wait));
      showHere = !await NotificationService().isShowing(notificationId);
      if (showHere) log('Scheduled alarm did not show at $scheduledTimeStr; showing it from the app');
    }
    if (showHere) {
      try {
        await NotificationService().showNotification(
          id: notificationId,
          title: 'Medicine Reminder',
          body: notificationBody,
          payload: payload,
        );
      } catch (e) {
        // Don't fail silently: say why, and still ask about the dose.
        log('Could not show reminder notification: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Reminder notification failed: $e'), duration: const Duration(seconds: 10)),
          );
          _showConfirmationDialog(payload);
        }
      }
    }

    // Start the in-app missed-dose tracking only if the background alarms
    // couldn't be set (they handle follow-ups and the 30-minute check).
    if (_remindersScheduled) return;
    final due = DateTime(now.year, now.month, now.day, now.hour, now.minute);
    try {
      await EscalationService().startTracking(
        medicinesPayload
            .map((m) => PendingDose(
                  medicine: m['name'] ?? '',
                  dosage: m['dosage'] ?? '',
                  slot: m['slot'] ?? '',
                  date: dateStr,
                  time: scheduledTimeStr,
                  due: due,
                ))
            .toList(),
        payload,
      );
    } catch (e) {
      log('Could not start escalation tracking: $e');
    }
  }

  Future<void> _showConfirmationDialog(String payload) async {
    if (!mounted) return;

    Map<String, dynamic> data;
    try {
      data = jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return; // Malformed payload — silently ignore
    }

    final List<dynamic> medicinesData = (data['medicines'] as List?) ?? [];
    if (medicinesData.isEmpty) return;
    final String date = (data['date'] as String?)?.isNotEmpty == true
        ? data['date'] as String
        : DateTime.now().toIso8601String().split('T')[0];
    final String time = (data['time'] as String?)?.isNotEmpty == true
        ? data['time'] as String
        : formatTime(TimeOfDay.fromDateTime(DateTime.now()));

    List<String> medicineNames = medicinesData.map((m) => m['name'] as String).toList();

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Confirm Medicine Intake'),
          content: Text('Are you going to take the following medicine(s) now?\n\n${medicineNames.join(', ')}'),
          actions: <Widget>[
            TextButton(
              child: const Text('No'),
              onPressed: () {
                Navigator.of(context).pop();
                for (var medData in medicinesData) {
                  EscalationService().resolve(
                    medicine: medData['name'] as String,
                    date: date,
                    time: time,
                    taken: false,
                  );
                }
                ReminderScheduler.skipFollowUpsFor(date: date, time: time);
              },
            ),
            TextButton(
              child: const Text('Yes'),
              onPressed: () {
                Navigator.of(context).pop();
                for (var medData in medicinesData) {
                  EscalationService().resolve(
                    medicine: medData['name'] as String,
                    date: date,
                    time: time,
                    taken: true,
                  );
                }
                ReminderScheduler.skipFollowUpsFor(date: date, time: time);
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _loadPairedDevice() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        pairedDeviceName = prefs.getString('pillbox_name');
      });
    }
  }

  Future<void> _fetchUserData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      // Load profile name from Firestore for greeting fallback
      try {
        final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
        if (doc.exists) {
          final data = doc.data();
          if (mounted) {
            setState(() {
              givenName = (data?['name'] as String?)?.trim();
            });
          }
        }
      } catch (_) {}
      await _fetchSchedules(user.uid);
      await _fetchPillBoxAssignments(user.uid);
      await _syncReminders();
      await _catchUpRecentDoses();
    }
  }

  // ---------- Reminders that work when the app is closed ----------
  Future<void> _syncReminders() async {
    try {
      final count = await ReminderScheduler.sync(allMedicines, pillBoxAssignments);
      _remindersScheduled = count > 0;
      log('Scheduled $count weekly reminder alarm(s)');
    } catch (e) {
      _remindersScheduled = false;
      log('Could not schedule reminders: $e');
    }
    // Also give the PillPalBox its own copy, so it lights up even when the
    // phone is not connected. (Skipped if the box is not connected right now.)
    _syncPillBox();
  }

  void _syncPillBox() {
    if (!_schedulesLoaded || !_slotsLoaded) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final name = (givenName?.isNotEmpty == true)
        ? givenName!
        : (user.displayName?.isNotEmpty == true ? user.displayName! : (user.email ?? 'PillPal user'));
    unawaited(PillBoxSync.sync(allMedicines, pillBoxAssignments, userUid: user.uid, userName: name));
  }

  /// Another account's medicines are in the box: ask before replacing them.
  Future<bool> _confirmReplaceBox(String ownerName) async {
    if (!mounted) return false;
    final who = ownerName.isEmpty ? 'another account' : ownerName;
    final replace = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Use this PillPalBox?'),
        content: Text(
          'This PillPalBox has medicines set up by $who.\n\n'
          'If you continue, their list in the box is replaced with your medicines, '
          'and the box will show you as its user.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text("Keep $who's")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF116FA9), foregroundColor: Colors.white),
            child: const Text('Replace with mine'),
          ),
        ],
      ),
    );
    return replace == true;
  }

  /// If a reminder fired while the app was closed and the dose isn't logged
  /// yet, start the missed-dose escalation for it now (doses from the last 30 min).
  Future<void> _catchUpRecentDoses() async {
    if (_remindersScheduled) return; // background alarms already cover this
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final now = DateTime.now();
    final today = daysOfWeek[now.weekday - 1];
    final dateStr = dateKey(now);
    try {
      final logDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('logs')
          .doc(dateStr)
          .get();
      final intakes = (logDoc.data()?['intakes'] as List?) ?? [];
      final doses = <PendingDose>[];
      final payloadMeds = <Map<String, String>>[];
      String? payloadTime;
      for (final med in medicines) {
        if (!(med['repeatDays'] as List).contains(today)) continue;
        if (!runsOn(med['endDate'] as String?, now)) continue;
        for (final t in (med['schedules'] as List).cast<TimeOfDay>()) {
          final due = DateTime(now.year, now.month, now.day, t.hour, t.minute);
          if (due.isAfter(now) || !due.isAfter(now.subtract(EscalationService.missedAfter))) continue;
          final timeStr = formatTime(t);
          final logged = intakes.any((i) => i['medicine'] == med['name'] && i['time'] == timeStr);
          if (logged) continue;
          final assignment = pillBoxAssignments.firstWhere(
            (a) => a['medicine'] == med['name'],
            orElse: () => <String, String>{},
          );
          final slot = (assignment['slot'] ?? '').toUpperCase();
          doses.add(PendingDose(
            medicine: med['name'] as String,
            dosage: (med['dosage'] ?? '') as String,
            slot: slot,
            date: dateStr,
            time: timeStr,
            due: due,
          ));
          payloadMeds.add({'name': med['name'] as String, 'dosage': (med['dosage'] ?? '') as String, 'slot': slot});
          payloadTime = timeStr;
        }
      }
      if (doses.isEmpty) return;
      final payload = jsonEncode({'medicines': payloadMeds, 'date': dateStr, 'time': payloadTime});
      await EscalationService().startTracking(doses, payload);
    } catch (e) {
      log('Catch-up check failed: $e');
    }
  }

  Map<String, dynamic> _medicineFromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final List<TimeOfDay> schedules = ((data['schedules'] as List<dynamic>?) ?? []).map((s) {
      return TimeOfDay(hour: (s['hour'] as num).toInt(), minute: (s['minute'] as num).toInt());
    }).toList();

    final Timestamp? createdTs = data['createdAt'] as Timestamp?;
    final DateTime createdAt = createdTs != null ? createdTs.toDate() : DateTime.now();

    return {
      'id': doc.id,
      'name': data['name'],
      'dosage': data['dosage'],
      'schedules': schedules,
      'repeatDays': ((data['repeatDays'] as List<dynamic>?) ?? []).cast<String>(),
      'createdAt': createdAt,
      'isActive': data['isActive'] ?? true,
      'endDate': data['endDate'] as String?, // last day of a limited course
    };
  }

  Future<void> _fetchSchedules(String userId) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('schedules')
          .get();

      final fetchedMedicines = snapshot.docs.map(_medicineFromDoc).toList();
      _schedulesLoaded = true;

      if (mounted) {
        setState(() {
          allMedicines = fetchedMedicines;
          medicines = fetchedMedicines.where((m) => m['isActive'] == true).toList();
        });
      }
    } catch (e) {
      // Handle error, e.g., show a snackbar
    }
    _listenForScheduleChanges(userId);
  }

  /// Keeps the list and the reminder alarms up to date when a schedule is
  /// changed somewhere else (for example by a caregiver on their phone).
  void _listenForScheduleChanges(String userId) {
    _schedulesSub?.cancel();
    var first = true;
    final announced = <String>{}; // each caregiver edit is shown once
    _schedulesSub = FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('schedules')
        .snapshots()
        .listen((snap) async {
      if (first) {
        first = false; // same data as the fetch above
        return;
      }
      if (snap.metadata.hasPendingWrites) return; // our own change, already applied

      final fromOthers = <String>[];
      for (final change in snap.docChanges) {
        final d = change.doc.data();
        if (d == null || change.type != DocumentChangeType.modified) continue;
        final editKey = '${change.doc.id}:${(d['updatedAt'] as Timestamp?)?.millisecondsSinceEpoch}';
        if (d['updatedBy'] != null && d['updatedBy'] != userId && announced.add(editKey)) {
          fromOthers.add('${d['updatedByName'] ?? 'Your caregiver'} updated ${d['name']}');
        }
        // A caregiver renamed a medicine: rename its PillPalBox slot too.
        final renamedFrom = d['renamedFrom'] as String?;
        if (renamedFrom != null) {
          await _renameSlotMedicine(renamedFrom, (d['name'] ?? '').toString());
          try {
            await change.doc.reference.update({'renamedFrom': FieldValue.delete()});
          } catch (_) {}
        }
      }

      final updated = snap.docs.map(_medicineFromDoc).toList();
      _schedulesLoaded = true;
      if (!mounted) return;
      setState(() {
        allMedicines = updated;
        medicines = updated.where((m) => m['isActive'] == true).toList();
      });
      await _syncReminders();
      if (fromOthers.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(fromOthers.join('\n'))));
      }
    }, onError: (e) => log('Schedule updates stopped: $e'));
  }

  /// Renames a medicine in the PillPalBox slots (slots match by name).
  Future<void> _renameSlotMedicine(String oldName, String newName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || newName.trim().isEmpty) return;
    var changed = false;
    final updated = pillBoxAssignments.map((slot) {
      if ((slot['medicine'] ?? '').trim().toLowerCase() == oldName.trim().toLowerCase()) {
        changed = true;
        return {...slot, 'medicine': newName.trim()};
      }
      return slot;
    }).toList();
    if (!changed) return;
    if (mounted) setState(() => pillBoxAssignments = updated);
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set({'pillbox_assignments': updated}, SetOptions(merge: true));
    } catch (e) {
      log('Could not rename PillPalBox slot: $e');
    }
  }

  /// Patient side: edit one of their scheduled medicines.
  Future<void> _editMedicine(Map<String, dynamic> med) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final oldName = (med['name'] ?? '').toString();
    final edit = await showMedicineEditor(context, initial: MedicineEdit.fromLocal(med));
    if (edit == null || !mounted) return;
    try {
      await ScheduleEdits.save(
        ownerUid: user.uid,
        scheduleId: med['id'] as String,
        edit: edit,
        oldName: oldName,
        editorName: givenName,
      );
      if (edit.name.toLowerCase() != oldName.toLowerCase()) {
        await _renameSlotMedicine(oldName, edit.name);
      }
      if (!mounted) return;
      setState(() {
        final i = allMedicines.indexWhere((m) => m['id'] == med['id']);
        if (i != -1) {
          allMedicines[i] = {
            ...allMedicines[i],
            'name': edit.name,
            'dosage': edit.dosage,
            'schedules': edit.times,
            'repeatDays': edit.days,
            'endDate': edit.endDate,
          };
        }
        medicines = allMedicines.where((m) => m['isActive'] == true).toList();
      });
      await _syncReminders();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${edit.name} updated.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save changes: $e')));
      }
    }
  }

  Future<void> _fetchPillBoxAssignments(String userId) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
      final docData = doc.data();
      // Always replace (empty if this account has no slots yet), so nothing
      // from a previously logged-in account is left behind.
      final assignments = (docData?['pillbox_assignments'] as List<dynamic>? ?? [])
          .map((item) => Map<String, String>.from(item as Map))
          .toList();
      _slotsLoaded = true;
      if (mounted) {
        setState(() {
          pillBoxAssignments = assignments;
        });
      }
    } catch (e) {
      if (mounted) setState(() => pillBoxAssignments = []);
    }
  }

  void _switchPage(String page) {
    setState(() {
      activePage = page;
    });
  }

  Future<void> _logout(BuildContext context) async {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Logout'),
          content: const Text('Are you sure you want to log out?'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            TextButton(
              child: const Text('Logout'),
              onPressed: () async {
                Navigator.of(dialogContext).pop(); // Close dialog
                await ReminderScheduler.cancelAll(); // stop this user's alarms
                await EscalationService().resetForLogout(); // forget this user's pending doses
                await FirebaseAuth.instance.signOut();
              },
            ),
          ],
        );
      },
    );
  }

  /// Saves several scanned medicines as schedules in one go.
  Future<int> _saveScannedMedicines(List<ScannedMedicineDraft> drafts) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || drafts.isEmpty) return 0;
    final col = FirebaseFirestore.instance.collection('users').doc(user.uid).collection('schedules');
    final batch = FirebaseFirestore.instance.batch();
    final added = <Map<String, dynamic>>[];
    for (final d in drafts) {
      final ref = col.doc();
      final dosage = d.dosage.isEmpty ? ScannedMedicineDraft.defaultDosage : d.dosage;
      batch.set(ref, {
        'name': d.name,
        'dosage': dosage,
        'schedules': d.times.map((t) => {'hour': t.hour, 'minute': t.minute}).toList(),
        'repeatDays': d.days,
        if (d.endDate != null) 'endDate': d.endDate,
        'createdAt': FieldValue.serverTimestamp(),
        'isActive': true,
      });
      added.add({
        'id': ref.id,
        'name': d.name,
        'dosage': dosage,
        'schedules': List<TimeOfDay>.of(d.times),
        'repeatDays': List<String>.of(d.days),
        'endDate': d.endDate,
        'createdAt': DateTime.now(),
        'isActive': true,
      });
    }
    await batch.commit();
    if (mounted) {
      setState(() {
        allMedicines.addAll(added);
        medicines = allMedicines.where((m) => m['isActive'] == true).toList();
      });
    }
    _syncReminders();
    return added.length;
  }

  void _addMedicine() {
    final nameController = TextEditingController();
    final dosageController = TextEditingController();
    List<String> selectedDays = [];
    List<TimeOfDay> schedules = [const TimeOfDay(hour: 12, minute: 0)];
    String? endDate; // last day of a limited course, null = ongoing
    List<String> availableMedicines =
    pillBoxAssignments.map((e) => e['medicine'] ?? '').where((m) => m.trim().isNotEmpty).toList();
    bool isScanning = false;
    bool handwritten = false;
    String? scanNote;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(builder: (context, setStateDialog) {
          // ---------- Scan-to-Schedule ----------
          Future<void> runScan(ImageSource source) async {
            setStateDialog(() {
              isScanning = true;
              scanNote = null;
            });
            try {
              final List<ScanResult>? results;
              if (handwritten) {
                results = await PrescriptionScanner.scanWithAi(source);
              } else {
                results = await PrescriptionScanner.scan(source);
              }
              if (!context.mounted) return;
              if (results == null) {
                setStateDialog(() => isScanning = false);
                return;
              }
              final named = results.where((r) => r.name != null && r.name!.trim().isNotEmpty).toList();
              if (named.length > 1) {
                // Several medicines on one prescription: review them all and
                // add the ticked ones in one go.
                final picked = await showScanReviewDialog(
                  context,
                  named,
                  medicines.map((m) => (m['name'] ?? '').toString()),
                );
                if (!context.mounted) return;
                if (picked == null) {
                  setStateDialog(() {
                    isScanning = false;
                    scanNote = 'Nothing added. You can scan again or fill in the form.';
                  });
                  return;
                }
                try {
                  final count = await _saveScannedMedicines(picked);
                  if (!context.mounted) return;
                  Navigator.of(context).pop(); // close Add New Schedule
                  if (mounted) {
                    ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(
                      content: Text('Added $count medicine${count == 1 ? '' : 's'} from the prescription.'),
                    ));
                  }
                } catch (e) {
                  if (!context.mounted) return;
                  setStateDialog(() {
                    isScanning = false;
                    scanNote = 'Could not save: $e';
                  });
                }
                return;
              }
              final result = named.isNotEmpty ? named.first : results.first;
              setStateDialog(() {
                isScanning = false;
                if (result.name != null) {
                  // Use the PillPalBox spelling if it matches, so the right slot lights up.
                  final match = availableMedicines.firstWhereOrNull(
                      (m) => m.toLowerCase() == result.name!.toLowerCase());
                  nameController.text = match ?? result.name!;
                }
                if (result.dosage != null) dosageController.text = result.dosage!;
                if (result.foundFrequency) schedules = List.of(result.times);
                selectedDays = List.of(result.days);
                if (result.durationDays != null) endDate = endDateForDays(result.durationDays!);
                scanNote = result.summary;
              });
            } catch (e) {
              if (!context.mounted) return;
              setStateDialog(() {
                isScanning = false;
                scanNote = 'Scan failed: $e';
              });
            }
          }

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('Add New Schedule', style: TextStyle(fontWeight: FontWeight.bold)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Scan a prescription or label', style: TextStyle(fontWeight: FontWeight.bold)),
                  CheckboxListTile(
                    value: handwritten,
                    onChanged: isScanning ? null : (v) => setStateDialog(() => handwritten = v ?? false),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Handwritten prescription'),
                    subtitle: const Text('Read by Gemini AI. Needs internet.'),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: isScanning ? null : () => runScan(ImageSource.camera),
                          icon: const Icon(Icons.document_scanner),
                          label: const Text('Camera'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: isScanning ? null : () => runScan(ImageSource.gallery),
                          icon: const Icon(Icons.photo_library),
                          label: const Text('Gallery'),
                        ),
                      ),
                    ],
                  ),
                  if (isScanning)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: LinearProgressIndicator(),
                    ),
                  if (isScanning && handwritten)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('Reading the handwriting. This can take a minute or two.',
                          style: TextStyle(fontSize: 12)),
                    ),
                  if (scanNote != null)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF116FA9).withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(scanNote!, style: const TextStyle(fontSize: 13)),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Medicine name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (availableMedicines.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    const Text('In your PillPalBox:', style: TextStyle(fontSize: 12, color: Colors.black54)),
                    Wrap(
                      spacing: 6,
                      children: availableMedicines
                          .map((m) => ActionChip(
                                label: Text(m),
                                onPressed: () => setStateDialog(() => nameController.text = m),
                              ))
                          .toList(),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextField(
                    controller: dosageController,
                    decoration: const InputDecoration(
                      labelText: 'Dosage (e.g., 1 pill)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Repeat on:', style: TextStyle(fontWeight: FontWeight.bold)),
                  Wrap(
                    spacing: 4.0,
                    children: daysOfWeek.map((day) {
                      final isSelected = selectedDays.contains(day);
                      return FilterChip(
                        label: Text(day),
                        selected: isSelected,
                        onSelected: (bool selected) {
                          setStateDialog(() {
                            if (selected) {
                              selectedDays.add(day);
                            } else {
                              selectedDays.remove(day);
                            }
                          });
                        },
                        backgroundColor: isSelected ? const Color(0xFF116FA9).withOpacity(0.3) : Colors.grey[200],
                        selectedColor: const Color(0xFF116FA9).withOpacity(0.8),
                        checkmarkColor: Colors.white,
                        labelStyle: TextStyle(color: isSelected ? Colors.white : Colors.black),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  const Text('Time:', style: TextStyle(fontWeight: FontWeight.bold)),
                  ...schedules.asMap().entries.map((entry) {
                    int idx = entry.key;
                    TimeOfDay time = entry.value;
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(time.format(context)),
                        IconButton(
                          icon: const Icon(Icons.edit),
                          onPressed: () async {
                            final TimeOfDay? picked = await showTimePicker(
                              context: context,
                              initialTime: time,
                            );
                            if (picked != null && picked != time) {
                              setStateDialog(() => schedules[idx] = picked);
                            }
                          },
                        ),
                        if (schedules.length > 1)
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () => setStateDialog(() => schedules.removeAt(idx)),
                          ),
                      ],
                    );
                  }),
                  TextButton(
                    onPressed: () => setStateDialog(() => schedules.add(const TimeOfDay(hour: 12, minute: 0))),
                    child: const Text('Add Time'),
                  ),
                  const SizedBox(height: 8),
                  const Text('How long:', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  CourseLengthPicker(endDate: endDate, onChanged: (v) => setStateDialog(() => endDate = v)),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final String selectedMedicine = nameController.text.trim();
                  if (selectedMedicine.isEmpty ||
                      dosageController.text.trim().isEmpty ||
                      selectedDays.isEmpty) {
                    setStateDialog(() => scanNote = 'Please fill in the medicine name, dosage, and at least one day.');
                  } else {
                    final user = FirebaseAuth.instance.currentUser;
                    if (user == null) return;

                    // Capture navigator before the async gap so the context
                    // remains valid after the Firestore call completes.
                    final nav = Navigator.of(context);

                    final validSchedules = schedules.map((t) => {'hour': t.hour, 'minute': t.minute}).toList();

                    try {
                      final docRef = await FirebaseFirestore.instance
                          .collection('users')
                          .doc(user.uid)
                          .collection('schedules')
                          .add({
                        'name': selectedMedicine,
                        'dosage': dosageController.text,
                        'schedules': validSchedules,
                        'repeatDays': selectedDays,
                        if (endDate != null) 'endDate': endDate,
                        'createdAt': FieldValue.serverTimestamp(),
                        'isActive': true,
                      });

                      final newMedicine = {
                        'id': docRef.id,
                        'name': selectedMedicine,
                        'dosage': dosageController.text,
                        'schedules': schedules, // Keep as TimeOfDay for local state
                        'repeatDays': selectedDays,
                        'endDate': endDate,
                        'createdAt': DateTime.now(),
                        'isActive': true,
                      };
                      if (mounted) {
                        setState(() {
                          allMedicines.add(newMedicine);
                          medicines = allMedicines.where((m) => m['isActive'] == true).toList();
                        });
                      }
                      _syncReminders();
                      nav.pop();
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          SnackBar(content: Text('Failed to save schedule: $e')),
                        );
                      }
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF116FA9),
                  foregroundColor: Colors.white,
                ),
                child: const Text('Save'),
              ),
            ],
          );
        });
      },
    );
  }

  void _managePillBox() {
    List<Map<String, String>> tempAssignedSlots = pillBoxAssignments.isNotEmpty
        ? List.from(pillBoxAssignments.map((e) => Map<String, String>.from(e)))
        : [{'slot': 'A', 'medicine': ''}];

    // Slot choices come only from the medicines in the user's schedules,
    // so a slot can never be assigned a name that doesn't match a schedule.
    final List<String> medicineOptions = <String>[];
    for (final m in medicines) {
      final name = (m['name'] ?? '').toString().trim();
      if (name.isNotEmpty &&
          !medicineOptions.any((o) => o.toLowerCase() == name.toLowerCase())) {
        medicineOptions.add(name);
      }
    }
    String? matchOption(String? typed) {
      final t = (typed ?? '').trim().toLowerCase();
      if (t.isEmpty) return null;
      for (final o in medicineOptions) {
        if (o.toLowerCase() == t) return o;
      }
      return null; // old free-typed name with no matching schedule
    }
    List<String?> selectedMedicines =
        tempAssignedSlots.map((slot) => matchOption(slot['medicine'])).toList();

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            int remainingSlots = 6 - tempAssignedSlots.length;

            // Bluetooth-related state
            BluetoothState bluetoothState = BluetoothState.UNKNOWN;
            final FlutterBluetoothSerial bluetooth = FlutterBluetoothSerial.instance;
            List<BluetoothDevice> devicesList = [];
            bool isScanning = false;

            // Load Bluetooth state and saved device on first build
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              bluetoothState = await bluetooth.state;
              if(mounted) {
                 setStateDialog(() {});
              }
            });

            // Bluetooth functions
            Future<bool> _requestBluetoothPermissions() async {
              Map<Permission, PermissionStatus> statuses = await [
                Permission.bluetoothScan,
                Permission.bluetoothConnect,
                Permission.locationWhenInUse,
              ].request();

              if ((statuses[Permission.bluetoothScan]?.isGranted ?? false) &&
                  (statuses[Permission.bluetoothConnect]?.isGranted ?? false) &&
                  (statuses[Permission.locationWhenInUse]?.isGranted ?? false)) {
                return true;
              } else {
                if(mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Bluetooth and Location permissions are required to scan for devices.')),
                  );
                }
                return false;
              }
            }

            void _startScan(StateSetter innerSetState, BuildContext dialogCtx) async {
              if (!await _requestBluetoothPermissions()) return;

              // Ensure adapter enabled
              bluetoothState = await bluetooth.state;
              if (!bluetoothState.isEnabled) {
                await bluetooth.requestEnable();
                bluetoothState = await bluetooth.state;
                if (!bluetoothState.isEnabled) {
                  if(mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please enable Bluetooth to scan.')),
                    );
                  }
                  return;
                }
              }

              // Reset list and show paired devices first
              innerSetState(() {
                isScanning = true;
                devicesList = [];
              });

              try {
                final bonded = await bluetooth.getBondedDevices();
                if (dialogCtx.mounted) {
                  innerSetState(() {
                    for (final d in bonded) {
                      final exists = devicesList.any((x) => x.address == d.address);
                      if (!exists) devicesList.add(d);
                    }
                  });
                }
              } catch (_) {}

              try { await bluetooth.cancelDiscovery(); } catch (_) {}

              final discoverySub = bluetooth.startDiscovery().listen((r) {
                if (dialogCtx.mounted) {
                  innerSetState(() {
                    final existingIndex = devicesList.indexWhere((device) => device.address == r.device.address);
                    if (existingIndex < 0) {
                      devicesList.add(r.device);
                    }
                  });
                }
              }, onDone: () async {
                if (dialogCtx.mounted) {
                  innerSetState(() => isScanning = false);
                }
              });

              // Stop after 12 seconds
              Future.delayed(const Duration(seconds: 12), () async {
                try { await bluetooth.cancelDiscovery(); } catch (_) {}
                try { await discoverySub.cancel(); } catch (_) {}
                if (dialogCtx.mounted) {
                  innerSetState(() => isScanning = false);
                  if (devicesList.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('No devices found. Ensure HC-05 is powered and in range.')),
                    );
                  }
                }
              });
            }

            Future<void> _connectToDevice(BluetoothDevice device, BuildContext dialogContext, StateSetter outerSetState) async {
              try {
                // Stop discovery before attempting to connect to improve success rate
                try { await bluetooth.cancelDiscovery(); } catch (_) {}
                await BluetoothService().disconnect(); // Disconnect from old device

                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('pillbox_address', device.address);
                await prefs.setString('pillbox_name', device.name ?? 'Unknown Device');

                // Update the main state for the name
                if(mounted) {
                  setState(() {
                    pairedDeviceName = device.name ?? 'Unknown Device';
                  });
                }
                

                // Attempt to connect to the new device
                final ok = await BluetoothService().connect(retries: 5);
                if(!ok && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Failed to connect. Ensure device is powered and nearby.')),
                  );
                }

                if(mounted) {
                   outerSetState(() {}); // update dialog state
                }
               

                Navigator.pop(dialogContext); // Close the bluetooth selection dialog

                if(mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Set ${device.name ?? device.address} as active device')),
                  );
                }
                
              } catch (e) {
                if(mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to set device: $e')),
                  );
                }
              }
            }

            void _showBluetoothDialog() {
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (BuildContext dialogContext) {
                  return StatefulBuilder(
                    builder: (context, innerSetState) {
                      return AlertDialog(
                        title: const Text('Bluetooth Connection'),
                        content: SizedBox(
                          width: double.maxFinite,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Bluetooth'),
                                  Switch(
                                    value: bluetoothState.isEnabled,
                                    onChanged: (bool value) async {
                                      if (value) {
                                        await bluetooth.requestEnable();
                                      } else {
                                        await bluetooth.requestDisable();
                                      }
                                      bluetoothState = await bluetooth.state;
                                      if(mounted) {
                                         innerSetState(() {});
                                      }
                                    },
                                  ),
                                ],
                              ),
                              const Divider(),
                              ElevatedButton(
                                onPressed: bluetoothState.isEnabled ? () => _startScan(innerSetState, context) : null,
                                child: isScanning
                                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Text('Scan for Devices'),
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                height: 200,
                                child: ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: devicesList.length,
                                  itemBuilder: (context, index) {
                                    final device = devicesList[index];
                                    return ListTile(
                                      title: Text(device.name ?? 'Unknown Device'),
                                      subtitle: Text(device.address),
                                      onTap: () => _connectToDevice(device, dialogContext, setStateDialog),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(dialogContext).pop(),
                            child: const Text('Close'),
                          )
                        ],
                      );
                    },
                  );
                },
              );
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text('PillPalBox Manager', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Active PillPalBox', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              if (!isPillBoxConnected) {
                                BluetoothService().connect();
                                if(mounted) {
                                   setStateDialog(() {}); // To show "Connecting..."
                                }
                              }
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                              child: Text(
                                isPillBoxConnected
                                    ? (pairedDeviceName ?? 'Connected')
                                    : 'Disconnected. Tap to reconnect.',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.more_horiz, color: Colors.black87),
                          onPressed: _showBluetoothDialog,
                        ),
                      ],
                    ),
                    // Who last put their medicine list in the box.
                    ValueListenableBuilder<PillBoxOwner?>(
                      valueListenable: PillBoxSync.boxOwner,
                      builder: (context, owner, _) {
                        if (!isPillBoxConnected || owner == null) return const SizedBox.shrink();
                        final me = FirebaseAuth.instance.currentUser?.uid;
                        final text = owner.uid.isEmpty
                            ? 'No medicines saved in the box yet'
                            : owner.uid == me
                                ? 'Medicines in the box: yours (${owner.name})'
                                : 'Medicines in the box: set up by ${owner.name}';
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              Icon(
                                owner.uid.isNotEmpty && owner.uid != me ? Icons.person_outline : Icons.check_circle_outline,
                                size: 16,
                                color: owner.uid.isNotEmpty && owner.uid != me ? Colors.orange : Colors.green,
                              ),
                              const SizedBox(width: 6),
                              Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    const Text('Assign Medicine', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text('Slots Remaining ($remainingSlots)'),
                    const SizedBox(height: 8),
                    if (medicineOptions.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8.0),
                        child: Text(
                          'Add a medicine schedule first, then assign it to a slot.',
                          style: TextStyle(color: Colors.black54),
                        ),
                      ),
                    ...List.generate(tempAssignedSlots.length, (index) {
                      // Hide medicines already picked in another slot.
                      final taken = <String>{
                        for (int j = 0; j < selectedMedicines.length; j++)
                          if (j != index && selectedMedicines[j] != null) selectedMedicines[j]!,
                      };
                      final choices = medicineOptions
                          .where((o) => !taken.contains(o) || o == selectedMedicines[index])
                          .toList();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Row(
                          children: [
                            Text('Slot ${tempAssignedSlots[index]['slot']}'),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  color: Colors.black87,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    value: selectedMedicines[index],
                                    isExpanded: true,
                                    dropdownColor: Colors.black87,
                                    iconEnabledColor: Colors.white,
                                    iconDisabledColor: Colors.white38,
                                    style: const TextStyle(color: Colors.white),
                                    hint: const Text('Choose medicine',
                                        style: TextStyle(color: Colors.white54)),
                                    disabledHint: const Text('No medicines yet',
                                        style: TextStyle(color: Colors.white38)),
                                    items: [
                                      // "Empty" = no medicine in this slot.
                                      const DropdownMenuItem<String>(
                                        value: null,
                                        child: Text('Empty',
                                            style: TextStyle(color: Colors.white54, fontStyle: FontStyle.italic)),
                                      ),
                                      ...choices.map((name) => DropdownMenuItem<String>(
                                            value: name,
                                            child: Text(name, overflow: TextOverflow.ellipsis),
                                          )),
                                    ],
                                    onChanged: (value) {
                                      setStateDialog(() {
                                        selectedMedicines[index] = value;
                                      });
                                    },
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, color: Colors.black87),
                              onPressed: () {
                                if(mounted) {
                                  setStateDialog(() {
                                    if (tempAssignedSlots.length > 1) {
                                      tempAssignedSlots.removeAt(index);
                                      selectedMedicines.removeAt(index);
                                    }
                                  });
                                }
                              },
                            ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () {
                          if (tempAssignedSlots.length < 6) {
                            if(mounted) {
                              setStateDialog(() {
                                // Use the first free letter (A-F), even after a slot was removed.
                                final used = tempAssignedSlots.map((s) => s['slot']).toSet();
                                final next = List.generate(6, (i) => String.fromCharCode(65 + i))
                                    .firstWhere((l) => !used.contains(l));
                                tempAssignedSlots.add({'slot': next, 'medicine': ''});
                                selectedMedicines.add(null);
                              });
                            }
                          }
                        },
                        style: OutlinedButton.styleFrom(
                          side: BorderSide.none,
                          backgroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('Add More', style: TextStyle(color: Colors.black87)),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    for (int i = 0; i < tempAssignedSlots.length; i++) {
                      tempAssignedSlots[i]['medicine'] = selectedMedicines[i] ?? '';
                    }

                    // Keep empty slots too, so the box layout (A, B, C...) is
                    // remembered; an empty slot never matches a schedule.
                    final updatedAssignments = tempAssignedSlots
                        .map((slot) => Map<String, String>.from(slot))
                        .toList()
                      ..sort((a, b) => (a['slot'] ?? '').compareTo(b['slot'] ?? ''));
                    if (mounted) {
                      setState(() {
                        pillBoxAssignments = updatedAssignments;
                      });
                    }

                    final user = FirebaseAuth.instance.currentUser;
                    if (user != null) {
                      final nav = Navigator.of(context);
                      try {
                        await FirebaseFirestore.instance
                            .collection('users')
                            .doc(user.uid)
                            .set({
                          'pillbox_assignments': updatedAssignments,
                        }, SetOptions(merge: true));
                        _syncReminders();
                        nav.pop();
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            SnackBar(content: Text('Failed to save assignments: $e')),
                          );
                        }
                      }
                    } else {
                      Navigator.pop(context);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF116FA9),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showDeleteConfirmationDialog(Map<String, dynamic> medicineToDelete) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete Schedule'),
          content: Text('Are you sure you want to delete the schedule for "${medicineToDelete['name']}"?'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Delete'),
              onPressed: () async {
                final user = FirebaseAuth.instance.currentUser;
                if (user == null) {
                  Navigator.of(context).pop();
                  return;
                }

                final String scheduleId = medicineToDelete['id'];

                try {
                  // 1. "Soft delete" from Firestore by marking as inactive
                  await FirebaseFirestore.instance
                      .collection('users')
                      .doc(user.uid)
                      .collection('schedules')
                      .doc(scheduleId)
                      .update({'isActive': false});

                  // 2. Update local state to remove from UI
                  if(mounted) {
                    setState(() {
                      final index = allMedicines.indexWhere((m) => m['id'] == scheduleId);
                      if (index != -1) {
                        allMedicines[index]['isActive'] = false;
                      }
                      medicines = allMedicines.where((m) => m['isActive'] == true).toList();
                    });
                  }
                  _syncReminders();
                  
                  // 3. Close the dialog
                  Navigator.of(context).pop();

                } catch (e) {
                  // Handle error, maybe show a snackbar
                  Navigator.of(context).pop();
                  if(mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to delete schedule: $e'))
                  );
                  }
                }
              },
            ),
          ],
        );
      },
    );
  }

  String formatTime(TimeOfDay t) {
    final hour = t.hour == 0 ? 12 : t.hour > 12 ? t.hour - 12 : t.hour;
    final minute = t.minute.toString().padLeft(2, '0');
    final period = t.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  int timeToMin(String time) {
    var parts = time.split(' ');
    var hm = parts[0].split(':');
    int h = int.parse(hm[0]);
    int m = int.parse(hm[1]);
    if (parts[1] == 'PM' && h < 12) h += 12;
    if (parts[1] == 'AM' && h == 12) h = 0;
    return h * 60 + m;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: const Color(0xFF116FA9),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              child: Row(
                children: [
                  Image.asset('assets/icon.png', height: 50),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _headerButton("Dashboard"),
                            const SizedBox(width: 5),
                            _headerButton("History"),
                            const SizedBox(width: 5),
                            // TextButton(
                            //   onPressed: () {
                            //     Navigator.of(context).push(
                            //       MaterialPageRoute(builder: (_) => const DebugBluetoothPage()),
                            //     );
                            //   },
                            //   child: const Text("Debug", style: TextStyle(color: Colors.white)),
                            // ),
                            const SizedBox(width: 5),
                            TextButton.icon(
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => const CaregiverPage()),
                              ),
                              icon: const Icon(Icons.family_restroom, color: Colors.white, size: 18),
                              label: const Text("Care", style: TextStyle(color: Colors.white)),
                            ),
                            TextButton(
                              onPressed: () => _logout(context),
                              child: const Text("Logout", style: TextStyle(color: Colors.white)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: activePage == "Dashboard" ? _dashboardContent() : _historyContent(),
              ),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: AnimatedScale(
        duration: const Duration(milliseconds: 200),
        scale: activePage == "Dashboard" ? 1.0 : 0.0,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FloatingActionButton(
              heroTag: 'managePillBox',
              onPressed: _managePillBox,
              backgroundColor: const Color(0xFF116FA9),
              shape: const CircleBorder(),
              child: Image.asset('assets/icon.png', height: 30),
            ),
            const SizedBox(width: 16),
            FloatingActionButton(
              heroTag: 'addMedicine',
              onPressed: _addMedicine,
              backgroundColor: const Color(0xFF116FA9),
              shape: const CircleBorder(),
              child: const Icon(Icons.add, color: Colors.white, size: 30),
            ),
          ],
        ),
      ),
    );
  }

  Widget _headerButton(String text) {
    bool isActive = activePage == text;
    return GestureDetector(
      onTap: () => _switchPage(text),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          boxShadow: isActive
              ? [const BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 3))]
              : [],
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            text,
            style: TextStyle(
              color: isActive ? const Color(0xFF116FA9) : Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _dashboardContent() {
    return StreamBuilder<User?>(
        stream: FirebaseAuth.instance.userChanges(),
        builder: (context, snapshot) {
          final user = snapshot.data;
          final String displayName = user?.displayName ?? "";
          final String effectiveName = displayName.isNotEmpty
              ? displayName
              : (givenName?.isNotEmpty == true ? givenName! : "");
          final String greeting = effectiveName.isNotEmpty
              ? 'Hi, $effectiveName!'
              : 'Hi there!';

          int timeOfDayToMinutes(TimeOfDay tod) => tod.hour * 60 + tod.minute;

          return Padding(
            key: const ValueKey('DashboardList'),
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  greeting,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Your Scheduled Medicines',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.black54,
                  ),
                ),
                if (medicines.isNotEmpty)
                  const Text(
                    'Tap a medicine to edit it. Press and hold to delete.',
                    style: TextStyle(fontSize: 12, color: Colors.black45),
                  ),
                const SizedBox(height: 8),
                Expanded(
                  child: medicines.isEmpty
                      ? const Center(
                      child: Text(
                        'No schedules added yet.',
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ))
                      : ListView.builder(
                    itemCount: medicines.length,
                    itemBuilder: (context, index) {
                      final med = medicines[index];
                      final List<TimeOfDay> schedules = (med['schedules'] as List).cast<TimeOfDay>();
                      String nextSchedule = "No schedule";
                      if (schedules.isNotEmpty) {
                        final earliestSchedule = schedules.reduce(
                                (a, b) => timeOfDayToMinutes(a) < timeOfDayToMinutes(b) ? a : b);
                        nextSchedule = earliestSchedule.format(context);
                      }
                      final repeatDaysStr = (med['repeatDays'] as List).join(', ');
                      final String? endDate = med['endDate'] as String?;
                      final bool ended = !runsOn(endDate, DateTime.now());
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        color: ended ? Colors.grey[200] : null,
                        child: ListTile(
                          isThreeLine: true,
                          onTap: () => _editMedicine(med),
                          onLongPress: () => _showDeleteConfirmationDialog(med),
                          title: Text(med['name'], style: TextStyle(color: ended ? Colors.black45 : null)),
                          subtitle: Text(
                            'Next intake: ${ended ? 'none (finished)' : nextSchedule}\nDosage: ${med['dosage']}\nRepeat: $repeatDaysStr'
                            '${endDate != null ? '\n${courseText(endDate)}' : ''}',
                          ),
                          trailing: IconButton(
                            tooltip: 'Edit',
                            icon: const Icon(Icons.edit, color: Color(0xFF116FA9)),
                            onPressed: () => _editMedicine(med),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        });
  }

  Widget _historyContent() {
    final ButtonStyle activeButtonStyle = ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFF116FA9),
      foregroundColor: Colors.white,
    );
    final ButtonStyle inactiveButtonStyle = ElevatedButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: const Color(0xFF116FA9),
    );

    return Column(
      key: const ValueKey('HistoryPage'),
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: () => setState(() { historyMode = 'Daily'; }),
                style: historyMode == 'Daily' ? activeButtonStyle : inactiveButtonStyle,
                child: const Text('Daily Log'),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: () => setState(() { historyMode = 'Weekly'; }),
                style: historyMode == 'Weekly' ? activeButtonStyle : inactiveButtonStyle,
                child: const Text('Weekly Log'),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: () {
              final user = FirebaseAuth.instance.currentUser;
              if (user == null) return null;
              return FirebaseFirestore.instance
                  .collection('users')
                  .doc(user.uid)
                  .collection('logs')
                  .snapshots();
            }(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final data = snapshot.data;
              if (data == null) {
                return const Center(child: Text('No logs available.'));
              }
              if (historyMode == 'Daily') {
                return _buildDailyLogs(data);
              } else {
                return _buildWeeklyLogs(data);
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDailyLogs(QuerySnapshot snapshot) {
    final now = DateTime.now();
    List<Widget> cards = [];
    for (int i = 0; i < 7; i++) {
      final d = now.subtract(Duration(days: i));
      final dateStr = d.toIso8601String().split('T')[0];
      final dayName = DateFormat('EEEE').format(d);
      final dateDisplay = DateFormat('MMMM d, yyyy').format(d);

      final weekdayStr = daysOfWeek[d.weekday - 1];
      List<Map<String, dynamic>> expectedIntakes = [];
      for (var med in allMedicines) {
        if ((med['repeatDays'] as List).contains(weekdayStr) && runsOn(med['endDate'] as String?, d)) {
          for (var sch in med['schedules'] as List<TimeOfDay>) {
            final timeStr = formatTime(sch);
            expectedIntakes.add({'medicine': med['name'], 'time': timeStr, 'status': 'not_taken'});
          }
        }
      }

      final logDoc = snapshot.docs.firstWhereOrNull((doc) => doc.id == dateStr);
      final intakes = (logDoc?.data() as Map<String, dynamic>?)?['intakes'] as List? ?? [];
      for (var intake in intakes) {
        final med = intake['medicine'];
        final time = intake['time'];
        final status = intake['status'];
        final match = expectedIntakes.firstWhere(
              (e) => e['medicine'] == med && e['time'] == time,
          orElse: () => {},
        );
        if (match.isNotEmpty) {
          match['status'] = status;
        }
      }

      expectedIntakes.sort((a, b) => timeToMin(a['time']) - timeToMin(b['time']));

      cards.add(_buildDailyCard(dateDisplay, dayName, expectedIntakes));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: cards,
    );
  }

  Widget _buildWeeklyLogs(QuerySnapshot snapshot) {
    final now = DateTime.now();
    // weekday is 1=Mon … 7=Sun; subtract (weekday-1) days to land on Monday
    final currentWeekStart = now.subtract(Duration(days: now.weekday - 1));
    List<Widget> cards = [];
    for (int w = 0; w < 4; w++) {
      final ws = currentWeekStart.subtract(Duration(days: w * 7));
      final we = ws.add(const Duration(days: 6));
      String week;
      if (ws.month == we.month) {
        week = '${DateFormat('MMMM').format(ws)} ${ws.day} - ${we.day}, ${ws.year}';
      } else {
        week = '${DateFormat('MMMM').format(ws)} ${ws.day} - ${DateFormat('MMMM').format(we)} ${we.day}, ${ws.year}';
      }
      int onTime = 0;
      int missed = 0;
      for (int j = 0; j < 7; j++) {
        final day = ws.add(Duration(days: j));
        final dateStr = day.toIso8601String().split('T')[0];
        final logDoc = snapshot.docs.firstWhereOrNull((doc) => doc.id == dateStr);
        final intakes = (logDoc?.data() as Map<String, dynamic>?)?['intakes'] as List? ?? [];
        final loggedOnTime = intakes.where((i) => i['status'] == 'on_time').length;
        final loggedMissed = intakes.where((i) => i['status'] == 'missed').length;

        final weekdayStr = daysOfWeek[day.weekday - 1];
        int expectedSoFar = 0;
        for (var med in allMedicines) {
          final DateTime? createdAt = med['createdAt'] as DateTime?;
          // Only count expectations for days on/after creation date
          final bool isActiveByDay = createdAt == null
              ? false
              : DateTime(day.year, day.month, day.day).isAfter(DateTime(createdAt.year, createdAt.month, createdAt.day).subtract(const Duration(days: 1)));
          if (isActiveByDay &&
              runsOn(med['endDate'] as String?, day) &&
              (med['repeatDays'] as List).contains(weekdayStr)) {
            // Count only schedules that have already occurred for 'day'
            final List<TimeOfDay> scheds = (med['schedules'] as List).cast<TimeOfDay>();
            if (day.isBefore(DateTime(now.year, now.month, now.day))) {
              // Past days: all schedules have occurred
              expectedSoFar += scheds.length;
            } else if (DateTime(day.year, day.month, day.day).isAtSameMomentAs(DateTime(now.year, now.month, now.day))) {
              // Today: only schedules <= now
              int nowMin = now.hour * 60 + now.minute;
              expectedSoFar += scheds.where((t) => (t.hour * 60 + t.minute) <= nowMin).length;
            } else {
              // Future days: none yet
            }
          }
        }

        onTime += loggedOnTime;
        final int totalLogged = intakes.length;
        final int notLoggedSoFar = (expectedSoFar - totalLogged);
        missed += loggedMissed + (notLoggedSoFar > 0 ? notLoggedSoFar : 0); // prevent negatives
      }
      cards.add(_buildWeeklyCard(week, onTime, missed));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: cards,
    );
  }

  Widget _buildDailyCard(String date, String day, List<Map<String, dynamic>> intakes) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$date\n$day', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...intakes.map((intake) => Row(
              children: [
                Icon(intake['status'] == 'on_time' ? Icons.check : Icons.close, color: intake['status'] == 'on_time' ? Colors.green : Colors.red),
                const SizedBox(width: 8),
                Expanded(child: Text(intake['medicine'])),
                Text(intake['time']),
              ],
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildWeeklyCard(String week, int onTime, int missed) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(week),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 100,
                  height: 100,
                  child: SimplePieChart(onTime: onTime, missed: missed),
                ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$onTime On Time Intakes'),
                    Text('$missed Missed Intakes', style: const TextStyle(color: Colors.red)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class SimplePieChart extends StatelessWidget {
  final int onTime;
  final int missed;

  const SimplePieChart({super.key, required this.onTime, required this.missed});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: PieChartPainter(onTime: onTime, missed: missed),
    );
  }
}

class PieChartPainter extends CustomPainter {
  final int onTime;
  final int missed;

  PieChartPainter({required this.onTime, required this.missed});

  @override
  void paint(Canvas canvas, Size size) {
    final double total = onTime + missed.toDouble();
    if (total == 0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);

    final greenPaint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.fill;

    final redPaint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    final double greenSweep = 2 * math.pi * (onTime / total);
    canvas.drawArc(rect, -math.pi / 2, greenSweep, true, greenPaint);
    canvas.drawArc(rect, -math.pi / 2 + greenSweep, 2 * math.pi * (missed / total), true, redPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

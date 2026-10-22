import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_service.dart';
import 'time_utils.dart';

const String kInviteAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O or 1/I

/// 6-character invite code using only easy-to-read characters.
String generateInviteCode([Random? rnd]) {
  final r = rnd ?? Random.secure();
  return List.generate(6, (_) => kInviteAlphabet[r.nextInt(kInviteAlphabet.length)]).join();
}

/// Caregiver Companion Mode data layer.
///
/// Firestore layout:
///   invites/{code}                         -> {patientUid, patientName}
///   users/{patient}/caregivers/{caregiver} -> {name, email, inviteCode}
///   users/{caregiver}/patients/{patient}   -> {name}
///   users/{patient}/alerts/{id}            -> written by EscalationService
///   users/{patient}/nudges/{id}            -> reminders sent by a caregiver
class CaregiverService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String get _uid {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not logged in');
    return user.uid;
  }

  DocumentReference<Map<String, dynamic>> _user(String uid) => _db.collection('users').doc(uid);

  Future<String> myName() async {
    final user = FirebaseAuth.instance.currentUser;
    try {
      final doc = await _user(_uid).get();
      final name = (doc.data()?['name'] as String?)?.trim();
      if (name != null && name.isNotEmpty) return name;
    } catch (_) {}
    if (user?.displayName?.isNotEmpty == true) return user!.displayName!;
    return user?.email ?? 'PillPal user';
  }

  // ----- patient side -----
  Future<String> createInviteCode() async {
    final name = await myName();
    for (int attempt = 0; attempt < 5; attempt++) {
      final code = generateInviteCode();
      final ref = _db.collection('invites').doc(code);
      final existing = await ref.get();
      if (existing.exists) continue;
      await ref.set({
        'patientUid': _uid,
        'patientName': name,
        'createdAt': FieldValue.serverTimestamp(),
      });
      return code;
    }
    throw Exception('Could not create a code. Please try again.');
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> myCaregivers() =>
      _user(_uid).collection('caregivers').snapshots();

  Future<void> removeCaregiver(String caregiverUid) async {
    await _user(_uid).collection('caregivers').doc(caregiverUid).delete();
    try {
      await _user(caregiverUid).collection('patients').doc(_uid).delete();
    } catch (_) {}
  }

  // ----- caregiver side -----
  Future<String> linkWithCode(String rawCode) async {
    final code = rawCode.trim().toUpperCase();
    if (code.length != 6) throw Exception('The code has 6 characters.');
    final invite = await _db.collection('invites').doc(code).get();
    if (!invite.exists) throw Exception('Code not found. Check it and try again.');
    final data = invite.data()!;
    final patientUid = data['patientUid'] as String;
    final patientName = (data['patientName'] as String?) ?? 'Patient';
    if (patientUid == _uid) throw Exception("That's your own code. Enter it on your caregiver's phone.");

    final me = FirebaseAuth.instance.currentUser!;
    final batch = _db.batch();
    batch.set(_user(patientUid).collection('caregivers').doc(_uid), {
      'name': await myName(),
      'email': me.email,
      'inviteCode': code,
      'linkedAt': FieldValue.serverTimestamp(),
    });
    batch.set(_user(_uid).collection('patients').doc(patientUid), {
      'name': patientName,
      'linkedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
    return patientName;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> myPatients() =>
      _user(_uid).collection('patients').snapshots();

  Future<void> unlinkPatient(String patientUid) async {
    await _user(_uid).collection('patients').doc(patientUid).delete();
    try {
      await _user(patientUid).collection('caregivers').doc(_uid).delete();
    } catch (_) {}
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> schedulesOf(String patientUid) =>
      _user(patientUid).collection('schedules').snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> logsOf(String patientUid) =>
      _user(patientUid).collection('logs').snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> alertsOf(String patientUid) => _user(patientUid)
      .collection('alerts')
      .orderBy('createdAtMs', descending: true)
      .limit(20)
      .snapshots();

  Future<void> sendNudge(String patientUid, String message) async {
    await _user(patientUid).collection('nudges').add({
      'fromUid': _uid,
      'fromName': await myName(),
      'message': message,
      'handled': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}

/// Runs inside the app while it is open:
/// - patient side: shows reminders that caregivers send ("nudges")
/// - caregiver side: shows a notification for every new alert of a linked patient
class CareListeners {
  StreamSubscription? _nudgeSub;
  StreamSubscription? _patientsSub;
  final Map<String, StreamSubscription> _alertSubs = {};

  void start() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final db = FirebaseFirestore.instance;

    _nudgeSub = db
        .collection('users')
        .doc(user.uid)
        .collection('nudges')
        .where('handled', isEqualTo: false)
        .snapshots()
        .listen((snap) async {
      for (final doc in snap.docs) {
        final d = doc.data();
        await NotificationService().showNotification(
          id: stableId('nudge_${doc.id}'),
          title: 'Reminder from ${d['fromName'] ?? 'your caregiver'}',
          body: (d['message'] as String?) ?? 'Please take your medicine.',
        );
        await doc.reference.update({'handled': true});
      }
    }, onError: (_) {});

    _patientsSub = db
        .collection('users')
        .doc(user.uid)
        .collection('patients')
        .snapshots()
        .listen((snap) async {
      final ids = snap.docs.map((d) => d.id).toSet();
      for (final id in _alertSubs.keys.toList()) {
        if (!ids.contains(id)) {
          await _alertSubs.remove(id)?.cancel();
        }
      }
      final prefs = await SharedPreferences.getInstance();
      for (final doc in snap.docs) {
        if (_alertSubs.containsKey(doc.id)) continue;
        final patientName = (doc.data()['name'] as String?) ?? 'Your patient';
        final seenKey = 'cg_alert_seen_${doc.id}';
        final lastSeen = prefs.getInt(seenKey) ?? DateTime.now().millisecondsSinceEpoch;
        await prefs.setInt(seenKey, lastSeen);

        _alertSubs[doc.id] = db
            .collection('users')
            .doc(doc.id)
            .collection('alerts')
            .where('createdAtMs', isGreaterThan: lastSeen)
            .snapshots()
            .listen((alerts) async {
          for (final change in alerts.docChanges) {
            if (change.type != DocumentChangeType.added) continue;
            final a = change.doc.data();
            if (a == null) continue;
            await NotificationService().showNotification(
              id: stableId('alert_${change.doc.id}'),
              title: 'PillPal alert: $patientName',
              body: (a['message'] as String?) ?? 'New alert',
            );
            final ms = (a['createdAtMs'] as int?) ?? 0;
            if (ms > (prefs.getInt(seenKey) ?? 0)) await prefs.setInt(seenKey, ms);
          }
        }, onError: (_) {});
      }
    }, onError: (_) {});
  }

  void stop() {
    _nudgeSub?.cancel();
    _patientsSub?.cancel();
    for (final s in _alertSubs.values) {
      s.cancel();
    }
    _alertSubs.clear();
  }
}

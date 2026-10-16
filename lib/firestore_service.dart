
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class FirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Get the current user's UID
  String? get _userUid => _auth.currentUser?.uid;

  // --- Medicine Schedules --- //

  // Get a stream of medicine schedules for the current user
  Stream<QuerySnapshot> getSchedulesStream() {
    if (_userUid == null) throw Exception("User not logged in");
    return _firestore
        .collection('users')
        .doc(_userUid)
        .collection('schedules')
        .snapshots();
  }

  // Add a new medicine schedule
  Future<void> addSchedule(Map<String, dynamic> scheduleData) {
    if (_userUid == null) throw Exception("User not logged in");
    return _firestore
        .collection('users')
        .doc(_userUid)
        .collection('schedules')
        .add(scheduleData);
  }

  // Delete a medicine schedule
  Future<void> deleteSchedule(String scheduleId) {
    if (_userUid == null) throw Exception("User not logged in");
    return _firestore
        .collection('users')
        .doc(_userUid)
        .collection('schedules')
        .doc(scheduleId)
        .delete();
  }

  // --- PillPalBox Assignments --- //

  // Get a stream of PillPalBox assignments
  Stream<DocumentSnapshot> getPillPalBoxStream() {
    if (_userUid == null) throw Exception("User not logged in");
    return _firestore.collection('users').doc(_userUid).snapshots();
  }

  // Update a specific slot in the PillPalBox
  Future<void> updatePillPalBox(String slot, Map<String, String?> medicineData) {
    if (_userUid == null) throw Exception("User not logged in");
    return _firestore.collection('users').doc(_userUid).set(
      {
        'pillbox': {
          slot: medicineData,
        }
      },
      SetOptions(merge: true), // Merge to avoid overwriting the whole document
    );
  }
}

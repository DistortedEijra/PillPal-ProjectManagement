
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  final FirebaseAuth _firebaseAuth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Stream to listen for auth state changes
  Stream<User?> get authStateChanges => _firebaseAuth.authStateChanges();

  // Get current user
  User? get currentUser => _firebaseAuth.currentUser;

  // Sign up with email and password
  Future<String?> signUp({
    required String email,
    required String password,
    required String name,
    required String age,
    required String gender,
  }) async {
    try {
      // 1. Create user in Firebase Auth
      UserCredential userCredential = await _firebaseAuth
          .createUserWithEmailAndPassword(email: email, password: password)
          .timeout(_timeout);

      User? user = userCredential.user;

      if (user != null) {
        // 2. Create a document for the user in Firestore
        await _firestore.collection('users').doc(user.uid).set({
          'name': name,
          'age': age,
          'gender': gender,
          'email': email,
          'uid': user.uid,
        });
      }
      return null; // Success
    } on FirebaseAuthException catch (e) {
      return _friendlyAuthError(e);
    } on TimeoutException {
      return 'Sign up is taking too long. Check your internet connection and try again.';
    } catch (e) {
      return 'Sign up failed: $e';
    }
  }

  // Sign in with email and password
  Future<String?> signIn({required String email, required String password}) async {
    try {
      await _firebaseAuth
          .signInWithEmailAndPassword(email: email, password: password)
          .timeout(_timeout);
      return null; // Success
    } on FirebaseAuthException catch (e) {
      return _friendlyAuthError(e);
    } on TimeoutException {
      return 'Login is taking too long. Check your internet connection and try again.';
    } catch (e) {
      return 'Login failed: $e';
    }
  }

  // Never let the login button spin forever.
  static const Duration _timeout = Duration(seconds: 20);

  String _friendlyAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
      case 'invalid-email':
        return 'Wrong email or password.';
      case 'network-request-failed':
        return 'No internet connection. Check your data or Wi-Fi and try again.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a few minutes and try again.';
      case 'email-already-in-use':
        return 'An account with this email already exists. Try logging in.';
      case 'weak-password':
        return 'Password is too weak (use at least 6 characters).';
      default:
        return e.message ?? 'Login failed (${e.code}).';
    }
  }

  // Sign out
  Future<void> signOut() async {
    await _firebaseAuth.signOut();
  }
}

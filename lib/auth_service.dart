
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  final FirebaseAuth _firebaseAuth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Stream to listen for auth state changes
  Stream<User?> get authStateChanges => _firebaseAuth.authStateChanges();

  /// Like [authStateChanges], but also fires when the user's email becomes
  /// verified (after [refreshEmailVerified]), so the app can move on.
  Stream<User?> get userChanges => _firebaseAuth.userChanges();

  /// Accounts made before this date were created before email verification
  /// existed, so they can still log in without verifying.
  static final DateTime verificationRequiredFrom = DateTime.utc(2026, 10, 29);

  /// True if this user must verify their email before using the app.
  static bool needsEmailVerification(User user) {
    if (user.emailVerified) return false;
    final created = user.metadata.creationTime;
    return created == null || !created.toUtc().isBefore(verificationRequiredFrom);
  }

  static final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$');
  static bool looksLikeEmail(String email) => _emailPattern.hasMatch(email.trim());

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
        // 3. Email a verification link (the app waits on the Verify page).
        try {
          await user.updateDisplayName(name);
          await user.sendEmailVerification().timeout(_timeout);
        } catch (_) {
          // Not fatal: the Verify page has a "Resend email" button.
        }
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

  /// Sends (again) the verification link to the logged-in user.
  Future<String?> sendVerificationEmail() async {
    final user = _firebaseAuth.currentUser;
    if (user == null) return 'Please log in again.';
    try {
      await user.sendEmailVerification().timeout(_timeout);
      return null;
    } on FirebaseAuthException catch (e) {
      return _friendlyAuthError(e);
    } on TimeoutException {
      return 'Sending is taking too long. Check your internet connection and try again.';
    } catch (e) {
      return 'Could not send the email: $e';
    }
  }

  /// Re-reads the user from Firebase. Returns true once the email is verified.
  Future<bool> refreshEmailVerified() async {
    final user = _firebaseAuth.currentUser;
    if (user == null) return false;
    await user.reload().timeout(_timeout);
    final fresh = _firebaseAuth.currentUser;
    final verified = fresh?.emailVerified ?? false;
    // A new token makes userChanges() fire, so AuthWrapper opens the app.
    if (verified) await fresh!.getIdToken(true);
    return verified;
  }

  /// Emails a password reset link.
  Future<String?> sendPasswordReset(String email) async {
    if (!looksLikeEmail(email)) return 'Enter a valid email address.';
    try {
      await _firebaseAuth.sendPasswordResetEmail(email: email.trim()).timeout(_timeout);
      return null;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found') return 'No account uses this email.';
      return _friendlyAuthError(e);
    } on TimeoutException {
      return 'Sending is taking too long. Check your internet connection and try again.';
    } catch (e) {
      return 'Could not send the email: $e';
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
      case 'missing-email':
        return 'Enter your email address.';
      default:
        return e.message ?? 'Login failed (${e.code}).';
    }
  }

  // Sign out
  Future<void> signOut() async {
    await _firebaseAuth.signOut();
  }
}

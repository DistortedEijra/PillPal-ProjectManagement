
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:myapp4/auth_page.dart';
import 'package:myapp4/dashboard.dart';
import 'auth_service.dart';
import 'verify_email_page.dart';

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    final AuthService authService = AuthService();

    return StreamBuilder<User?>(
      // userChanges also fires when the email gets verified.
      stream: authService.userChanges,
      builder: (context, snapshot) {
        // User is logged in
        if (snapshot.connectionState == ConnectionState.active) {
          if (snapshot.hasData) {
            final user = snapshot.data!;
            // New accounts must open the link in the verification email first.
            if (AuthService.needsEmailVerification(user)) {
              return VerifyEmailPage(key: ValueKey('verify-${user.uid}'), user: user);
            }
            // Keyed by account, so switching accounts never reuses the
            // previous account's medicines or PillPalBox slots.
            return DashboardPage(key: ValueKey(snapshot.data!.uid));
          }
          // User is not logged in
          return const AuthPage();
        }

        // Show a loading indicator while checking auth state
        return const Scaffold(
          body: Center(
            child: CircularProgressIndicator(),
          ),
        );
      },
    );
  }
}

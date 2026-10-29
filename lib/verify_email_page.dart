import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'auth_service.dart';

const Color _brand = Color(0xFF116FA9);

/// Shown after sign up until the user opens the link Firebase emailed them.
/// Checks by itself every few seconds; the user can also resend the email or
/// go back and use another account.
class VerifyEmailPage extends StatefulWidget {
  final User user;
  const VerifyEmailPage({super.key, required this.user});

  @override
  State<VerifyEmailPage> createState() => _VerifyEmailPageState();
}

class _VerifyEmailPageState extends State<VerifyEmailPage> {
  final AuthService _auth = AuthService();
  Timer? _autoCheck;
  Timer? _cooldownTimer;
  int _cooldown = 0; // seconds until "Resend" can be tapped again
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _startCooldown(); // an email was just sent at sign up
    _autoCheck = Timer.periodic(const Duration(seconds: 5), (_) => _check(silent: true));
  }

  @override
  void dispose() {
    _autoCheck?.cancel();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldown = 60);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _check({bool silent = false}) async {
    if (_checking) return;
    _checking = true;
    if (!silent) setState(() {});
    try {
      final verified = await _auth.refreshEmailVerified();
      // When verified, AuthWrapper sees the change and opens the dashboard.
      if (!verified && !silent) {
        _snack('Not verified yet. Open the link in the email, then tap the button again.');
      }
    } catch (e) {
      if (!silent) _snack('Could not check: $e');
    } finally {
      _checking = false;
      if (mounted && !silent) setState(() {});
    }
  }

  Future<void> _resend() async {
    final error = await _auth.sendVerificationEmail();
    if (error == null) {
      _startCooldown();
      _snack('Email sent again to ${widget.user.email}.');
    } else {
      _snack(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _brand,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Container(
            width: 340,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.mark_email_unread_outlined, size: 64, color: _brand),
                const SizedBox(height: 12),
                const Text('Verify your email', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Text(
                  'We sent a link to\n${widget.user.email}\n\nOpen the email and tap the link. '
                  'This page opens PillPal by itself once you are verified.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                const Text(
                  "Can't find it? Check your Spam or Promotions folder.",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _checking ? null : () => _check(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _brand,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _checking
                        ? const SizedBox(
                            width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text("I've verified my email", style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _cooldown > 0 ? null : _resend,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(_cooldown > 0 ? 'Resend email (${_cooldown}s)' : 'Resend email'),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => _auth.signOut(),
                  child: const Text('Use a different account'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Sign up only accepts something that looks like an email address,
// since the verification link is sent there.
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp4/auth_service.dart';

void main() {
  test('valid email addresses', () {
    expect(AuthService.looksLikeEmail('arjie@tip.edu.ph'), isTrue);
    expect(AuthService.looksLikeEmail('  maria.cruz+pillpal@gmail.com '), isTrue);
  });

  test('not email addresses', () {
    expect(AuthService.looksLikeEmail(''), isFalse);
    expect(AuthService.looksLikeEmail('arjie'), isFalse);
    expect(AuthService.looksLikeEmail('arjie@gmail'), isFalse);
    expect(AuthService.looksLikeEmail('arjie @gmail.com'), isFalse);
    expect(AuthService.looksLikeEmail('a@b@c.com'), isFalse);
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_app_test/features/auth/domain/auth_session.dart';

void main() {
  group('AuthSession', () {
    test('isExpired is true past expiresAt', () {
      final session = AuthSession(
        accessToken: 'a',
        sessionId: 's',
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
        emailVerified: false,
        phoneNumberVerified: false,
      );
      expect(session.isExpired, isTrue);
    });

    test('isExpired is false before expiresAt', () {
      final session = AuthSession(
        accessToken: 'a',
        sessionId: 's',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        emailVerified: false,
        phoneNumberVerified: false,
      );
      expect(session.isExpired, isFalse);
    });

    test('copyWith only overrides specified fields', () {
      final original = AuthSession(
        accessToken: 'a',
        sessionId: 's',
        expiresAt: DateTime.utc(2030),
        emailVerified: false,
        phoneNumberVerified: false,
      );
      final updated = original.copyWith(accessToken: 'b');
      expect(updated.accessToken, 'b');
      expect(updated.sessionId, 's');
      expect(updated.expiresAt, DateTime.utc(2030));
    });
  });
}

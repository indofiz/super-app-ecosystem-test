import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/core/jwt/jwt_codec.dart';
import 'package:smart_app_test/features/auth/domain/auth_session.dart';

// Use HS256 so the alg-guard in JwtClaims.fromToken() accepts the token.
// Signature verification is Kong's job; tests only exercise payload parsing.
String _jwt(Map<String, dynamic> payload) {
  final header = encodeJwtSegment({'alg': 'HS256', 'typ': 'JWT'});
  return '$header.${encodeJwtSegment(payload)}.fake-sig';
}

void main() {
  group('AuthSession.fromToken expiresAt', () {
    test('prefers JWT exp claim over the passed fallback', () {
      final jwtExp = DateTime.utc(2030, 1, 1, 12);
      final fallback = DateTime.now().add(const Duration(minutes: 5));
      final token = _jwt({
        'sub': 'u',
        'exp': jwtExp.millisecondsSinceEpoch ~/ 1000,
      });

      final session = AuthSession.fromToken(
        accessToken: token,
        sessionId: 'sid',
        expiresAt: fallback,
      );

      expect(
        session.expiresAt.millisecondsSinceEpoch,
        jwtExp.millisecondsSinceEpoch,
      );
    });

    test('falls back to the passed expiresAt when the JWT has no exp', () {
      final fallback = DateTime.utc(2026, 6, 1);
      final token = _jwt({'sub': 'u'});

      final session = AuthSession.fromToken(
        accessToken: token,
        sessionId: 'sid',
        expiresAt: fallback,
      );

      expect(session.expiresAt, fallback);
    });

    test('falls back when the token is unparseable', () {
      final fallback = DateTime.utc(2026, 6, 1);
      final session = AuthSession.fromToken(
        accessToken: 'garbage',
        sessionId: 'sid',
        expiresAt: fallback,
      );
      expect(session.expiresAt, fallback);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/core/jwt/jwt_codec.dart';
import 'package:smart_app_test/features/auth/domain/jwt_claims.dart';

// Use RS256 (the real BFF alg) so the alg-guard in JwtClaims.fromToken()
// accepts the token. Signature verification is Kong's job; tests only
// exercise payload parsing.
String _jwt(Map<String, dynamic> payload) {
  final header = encodeJwtSegment({'alg': 'RS256', 'typ': 'JWT'});
  return '$header.${encodeJwtSegment(payload)}.fake-sig';
}

void main() {
  group('JwtClaims.exp', () {
    test('decodes a numeric exp (seconds since epoch) as UTC', () {
      final epochSec = 1_700_000_000;
      final claims = JwtClaims.fromToken(_jwt({'exp': epochSec}));
      expect(claims.exp, isNotNull);
      expect(claims.exp!.isUtc, isTrue);
      expect(
        claims.exp!.millisecondsSinceEpoch,
        epochSec * 1000,
      );
    });

    test('decodes a numeric-string exp', () {
      final claims = JwtClaims.fromToken(_jwt({'exp': '1700000000'}));
      expect(
        claims.exp?.millisecondsSinceEpoch,
        1_700_000_000 * 1000,
      );
    });

    test('null when exp claim is missing', () {
      final claims = JwtClaims.fromToken(_jwt({'sub': 'u'}));
      expect(claims.exp, isNull);
    });

    test('null when exp claim is not numeric', () {
      final claims = JwtClaims.fromToken(_jwt({'exp': 'never'}));
      expect(claims.exp, isNull);
    });

    test('null on an unparseable token', () {
      expect(JwtClaims.fromToken('not-a-jwt').exp, isNull);
      expect(JwtClaims.empty().exp, isNull);
    });
  });
}

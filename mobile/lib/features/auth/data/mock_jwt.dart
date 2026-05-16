import 'package:flutter/foundation.dart';

import '../../../core/config/auth_timings.dart';
import '../../../core/jwt/jwt_codec.dart';

/// Mints an unsigned fake JWT for development.
///
/// Used by both [MockAuthRepository] (for login/refresh) and
/// [MockVerificationRepository] (after a successful OTP verify, to
/// re-mint with the flipped flag). The signature segment is empty —
/// the real BFF signs with RS256 (asymmetric; Kong verifies with the
/// public key); consumers of the mock never check signatures. NEVER hand
/// this token to anything that does.
String mockJwt({
  required String sub,
  bool emailVerified = false,
  String? phoneNumber,
  bool phoneNumberVerified = false,
}) {
  // Refuse to mint unsigned tokens outside debug builds. In release mode
  // this line is unreachable because MockAuthRepository is also debug-only,
  // but the assert provides an explicit compile-time-visible signal.
  assert(kDebugMode, 'mockJwt() must not be called in release builds');
  final header = encodeJwtSegment({'alg': 'none', 'typ': 'JWT'});
  final payload = encodeJwtSegment({
    'iss': 'mock-bff',
    'sub': sub,
    'name': 'Mock User',
    'preferred_username': sub,
    'email': 'mock@example.test',
    'email_verified': emailVerified,
    if (phoneNumber != null) 'phone_number': phoneNumber,
    'phone_number_verified': phoneNumberVerified,
    'realm': 'pangkalpinang',
    'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'exp': DateTime.now().add(kMockSessionLifetime).millisecondsSinceEpoch ~/
        1000,
  });
  return '$header.$payload.';
}

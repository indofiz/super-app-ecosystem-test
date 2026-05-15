import 'package:flutter/foundation.dart';

import '../../../core/jwt/jwt_codec.dart';
import '../../../core/logging/auth_log.dart';
import '../../../core/logging/error_reporter.dart';

/// Pure helper for reading the BFF-minted internal JWT.
///
/// The token is RS256-signed by the BFF — we do NOT verify the signature
/// on-device (Kong does that). All we want here is a typed peek at the
/// payload so the UI can gate on `email_verified` / `phone_number_verified`
/// without a /auth/me round-trip after every refresh.
///
/// `JwtClaims.empty()` is returned on any decode failure so callers never
/// have to deal with null payloads. Verified-flag fields default to
/// `false` — never default to "verified" on parse error.
class JwtClaims {
  const JwtClaims({
    required this.raw,
    required this.emailVerified,
    required this.phoneNumberVerified,
    this.email,
    this.phoneNumber,
    this.sub,
    this.username,
    this.exp,
  });

  factory JwtClaims.empty() => const JwtClaims(
        raw: <String, dynamic>{},
        emailVerified: false,
        phoneNumberVerified: false,
      );

  /// Parse the payload of a JWS-compact-serialized token.
  ///
  /// Rejects tokens with `alg: none` or a missing `alg` header — these are
  /// unsigned and trivially forgeable. Does not verify the signature
  /// (that is Kong's job), but refuses to silently accept unsigned tokens.
  factory JwtClaims.fromToken(String jwt) {
    final parts = jwt.split('.');
    if (parts.length < 2) {
      // audit-004 M-01: the fail-closed path is correct, but the failure
      // must reach the C-01 sink so a BFF claim-shape rollout doesn't
      // silently drop verified flags across the user base.
      authLog('jwt', 'decode failed: token has <2 segments');
      ErrorReporter.instance.reportError(
        StateError('JwtClaims: token has <2 segments'),
        StackTrace.current,
        context: 'jwt.parse',
      );
      return JwtClaims.empty();
    }

    // Guard: reject alg:none and tokens with no alg header.
    final header = decodeJwtHeader(jwt);
    final alg = (header?['alg'] as String? ?? '').toLowerCase().trim();
    if (alg == 'none' || alg.isEmpty) {
      authLog('jwt', 'REJECTED: token alg="$alg" — unsigned tokens are not accepted');
      // audit-004 M-01 + M-06: dev/staging builds run `MockAuthRepository`
      // which mints alg=none tokens on every login — reporting those would
      // bury real signal. In release builds, an unsigned token at the
      // parse boundary is a five-alarm fire (mis-shipped USE_MOCK_AUTH, or
      // a downgrade attack against the BFF).
      if (kReleaseMode) {
        ErrorReporter.instance.reportError(
          StateError('JwtClaims: unsigned token rejected (alg="$alg")'),
          StackTrace.current,
          context: 'jwt.alg-none',
          fatal: true,
        );
      }
      return JwtClaims.empty();
    }

    final raw = decodeJwtSegment(parts[1]);
    if (raw == null) {
      authLog('jwt', 'decode failed: payload was not a JSON object');
      ErrorReporter.instance.reportError(
        StateError('JwtClaims: payload was not a JSON object'),
        StackTrace.current,
        context: 'jwt.parse',
      );
      return JwtClaims.empty();
    }
    return JwtClaims(
      raw: raw,
      email: raw['email'] as String?,
      emailVerified: raw['email_verified'] == true,
      phoneNumber: raw['phone_number'] as String?,
      phoneNumberVerified: raw['phone_number_verified'] == true,
      sub: raw['sub'] as String?,
      username: raw['username'] as String? ??
          raw['preferred_username'] as String?,
      exp: _decodeExp(raw['exp']),
    );
  }

  /// Decode the JWT `exp` claim (RFC 7519 §4.1.4: seconds since epoch).
  /// Tolerates the value being `num` or a numeric `String`. Anything else
  /// (including null) yields null — callers fall back to a wall-clock
  /// derived expiry. The returned [DateTime] is UTC, matching the JWT
  /// spec; `isExpired` checks against `DateTime.now()` which auto-aligns
  /// the comparison.
  static DateTime? _decodeExp(Object? raw) {
    final seconds = switch (raw) {
      num n => n.toInt(),
      String s => int.tryParse(s.trim()),
      _ => null,
    };
    if (seconds == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }

  final Map<String, dynamic> raw;
  final String? sub;
  final String? username;
  final String? email;
  final bool emailVerified;
  final String? phoneNumber;
  final bool phoneNumberVerified;

  /// Server-stamped expiry (`exp` claim). Authoritative — callers must
  /// prefer this over any wall-clock-derived expiry to avoid the device
  /// clock-skew failure mode (audit-002 C-03).
  final DateTime? exp;

  bool get fullyVerified => emailVerified && phoneNumberVerified;
}

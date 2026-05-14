import 'dart:convert';

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
  });

  factory JwtClaims.empty() => const JwtClaims(
        raw: <String, dynamic>{},
        emailVerified: false,
        phoneNumberVerified: false,
      );

  /// Parse the payload of a JWS-compact-serialized token. Does not
  /// validate signature, issuer, audience, or expiry — that's Kong's job.
  factory JwtClaims.fromToken(String jwt) {
    final parts = jwt.split('.');
    if (parts.length < 2) return JwtClaims.empty();
    try {
      final segment = parts[1];
      final padded = segment.padRight(
        segment.length + (4 - segment.length % 4) % 4,
        '=',
      );
      final decoded = utf8.decode(base64Url.decode(padded));
      final raw = jsonDecode(decoded);
      if (raw is! Map<String, dynamic>) return JwtClaims.empty();
      return JwtClaims(
        raw: raw,
        email: raw['email'] as String?,
        emailVerified: raw['email_verified'] == true,
        phoneNumber: raw['phone_number'] as String?,
        phoneNumberVerified: raw['phone_number_verified'] == true,
        sub: raw['sub'] as String?,
        username: raw['username'] as String? ??
            raw['preferred_username'] as String?,
      );
    } catch (_) {
      return JwtClaims.empty();
    }
  }

  final Map<String, dynamic> raw;
  final String? sub;
  final String? username;
  final String? email;
  final bool emailVerified;
  final String? phoneNumber;
  final bool phoneNumberVerified;

  bool get fullyVerified => emailVerified && phoneNumberVerified;
}

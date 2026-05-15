/// Low-level base64Url codec for a single JWS-compact JWT segment.
///
/// The JWT spec (RFC 7515 §2) requires base64Url *without* trailing `=`
/// padding on the wire, but Dart's `base64Url.decode` requires the input
/// length to be a multiple of 4. These helpers own that padding rule so
/// `JwtClaims.fromToken` (decode) and `MockAuthRepository._fakeJwt`
/// (encode) cannot drift.
///
/// Neither function verifies signatures, issuer, audience, or expiry —
/// that is Kong's job. These are bytes-in/bytes-out helpers.
library;

import 'dart:convert';

String encodeJwtSegment(Map<String, dynamic> json) {
  return base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
}

Map<String, dynamic>? decodeJwtSegment(String segment) {
  if (segment.isEmpty) return null;
  final mod = segment.length % 4;
  if (mod == 1) return null;
  final padded = mod == 0 ? segment : segment.padRight(segment.length + (4 - mod), '=');
  try {
    final decoded = utf8.decode(base64Url.decode(padded));
    final parsed = jsonDecode(decoded);
    return parsed is Map<String, dynamic> ? parsed : null;
  } catch (_) {
    return null;
  }
}

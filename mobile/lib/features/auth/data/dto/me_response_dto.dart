import 'package:equatable/equatable.dart';

import '../../../../core/network/bff_parse.dart';

/// Wire-shape DTO for `GET /auth/me`.
///
/// Roles are eagerly materialized via `List<String>.from(...)` so a
/// non-String element trips at the parse site, not in some downstream
/// `roles.contains` far away from any HTTP context (audit-002 L-04).
///
/// Field naming follows the documented REST convention (`emailVerified`,
/// `phoneNumberVerified`) — distinct from the JWT's OIDC snake_case
/// (`email_verified`, `phone_number_verified`). See audit-002 M-02.
class MeResponseDto extends Equatable {
  const MeResponseDto({
    required this.sub,
    required this.roles,
    this.username,
    this.email,
    this.emailVerified = false,
    this.phoneNumber,
    this.phoneNumberVerified = false,
    this.expiresAt,
  });

  factory MeResponseDto.fromJson(Map<String, dynamic> body) {
    final rolesRaw = body['roles'];
    final List<String> roles;
    if (rolesRaw == null) {
      roles = const [];
    } else if (rolesRaw is List) {
      // Eager materialization (audit-002 L-04). Throws at this site if any
      // element isn't a String — preserves the parse-time guarantee instead
      // of using the lazy `.cast<String>()`.
      try {
        roles = List<String>.from(rolesRaw);
      } on TypeError catch (e) {
        throw BffParseFailure('roles', 'wrong-type:List<String>', cause: e);
      }
    } else {
      throw BffParseFailure('roles', 'wrong-type:List');
    }

    final expiresAtRaw = body['expiresAt'];
    DateTime? expiresAt;
    if (expiresAtRaw != null) {
      if (expiresAtRaw is! String) {
        throw BffParseFailure('expiresAt', 'wrong-type:String');
      }
      expiresAt = DateTime.tryParse(expiresAtRaw);
      // tryParse returns null on garbage — leave [expiresAt] null. The
      // field is purely informational on the mobile side (`exp` from the
      // JWT is the auth source of truth — audit-002 C-03).
    }

    return MeResponseDto(
      sub: optionalString(body, 'sub') ?? '',
      username: optionalString(body, 'username'),
      email: optionalString(body, 'email'),
      emailVerified: optionalBool(body, 'emailVerified'),
      phoneNumber: optionalString(body, 'phoneNumber'),
      phoneNumberVerified: optionalBool(body, 'phoneNumberVerified'),
      roles: roles,
      expiresAt: expiresAt,
    );
  }

  final String sub;
  final String? username;
  final String? email;
  final bool emailVerified;
  final String? phoneNumber;
  final bool phoneNumberVerified;
  final List<String> roles;
  final DateTime? expiresAt;

  @override
  List<Object?> get props => [
        sub,
        username,
        email,
        emailVerified,
        phoneNumber,
        phoneNumberVerified,
        roles,
        expiresAt,
      ];
}

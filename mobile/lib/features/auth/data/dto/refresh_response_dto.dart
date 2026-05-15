import 'package:equatable/equatable.dart';

import '../../../../core/network/bff_parse.dart';

/// Wire-shape DTO for `POST /auth/refresh`.
///
/// Validation goes through `bff_parse.dart` so contract drift surfaces as a
/// typed [BffParseFailure] — the repository translates that into
/// `AuthFailure(refreshFailed)` (audit-002 C-01 + H-03).
///
/// `sessionId` is wire-optional: the BFF documents that it may omit the
/// field when the rotation does not change the session ID. Callers fall
/// back to the request's session ID (see `BffAuthApi.refresh`).
class RefreshResponseDto extends Equatable {
  const RefreshResponseDto({
    required this.accessToken,
    required this.expiresIn,
    this.sessionId,
  });

  factory RefreshResponseDto.fromJson(Map<String, dynamic> body) {
    return RefreshResponseDto(
      accessToken: requireString(body, 'access_token'),
      sessionId: optionalString(body, 'session_id'),
      expiresIn: requireInt(body, 'expires_in'),
    );
  }

  final String accessToken;
  final String? sessionId;
  final int expiresIn;

  @override
  List<Object?> get props => [accessToken, sessionId, expiresIn];
}

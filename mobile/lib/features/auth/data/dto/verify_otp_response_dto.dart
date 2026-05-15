import 'package:equatable/equatable.dart';

import '../../../../core/network/bff_parse.dart';

/// Wire-shape DTO for `POST /auth/{email,phone}/verify-otp`.
///
/// Wire shape matches refresh, but the contract is stricter:
/// `session_id` is required (a verify call always re-mints the session
/// and the BFF stamps a fresh ID), while `/refresh` may omit it when the
/// ID is unchanged. Modelled as a distinct DTO so the parse rule travels
/// with the type.
class VerifyOtpResponseDto extends Equatable {
  const VerifyOtpResponseDto({
    required this.accessToken,
    required this.sessionId,
    required this.expiresIn,
  });

  factory VerifyOtpResponseDto.fromJson(Map<String, dynamic> body) {
    return VerifyOtpResponseDto(
      accessToken: requireString(body, 'access_token'),
      sessionId: requireString(body, 'session_id'),
      expiresIn: requireInt(body, 'expires_in'),
    );
  }

  final String accessToken;
  final String sessionId;
  final int expiresIn;

  @override
  List<Object?> get props => [accessToken, sessionId, expiresIn];
}

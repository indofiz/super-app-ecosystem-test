import 'package:equatable/equatable.dart';

import '../../../../core/network/bff_parse.dart';

/// Wire-shape DTO for `POST /auth/{email,phone}/send-otp`.
///
/// Channel-specific defaults (`delivery` falls back to `email`/`wa`,
/// `expiresIn` to `kOtpDefaultTtl`) live in the repository — the DTO
/// reports what the wire said, the caller decides defaults.
///
/// `alreadyVerified` mirrors the documented `verified:true` short-circuit
/// returned by the BFF on a 200 when the channel was already verified.
class SendOtpResponseDto extends Equatable {
  const SendOtpResponseDto({
    this.delivery,
    this.expiresIn,
    this.alreadyVerified = false,
  });

  factory SendOtpResponseDto.fromJson(Map<String, dynamic> body) {
    return SendOtpResponseDto(
      delivery: optionalString(body, 'delivery'),
      expiresIn: optionalInt(body, 'expires_in'),
      alreadyVerified: optionalBool(body, 'verified'),
    );
  }

  final String? delivery;
  final int? expiresIn;
  final bool alreadyVerified;

  @override
  List<Object?> get props => [delivery, expiresIn, alreadyVerified];
}

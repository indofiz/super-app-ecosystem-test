import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/core/network/bff_parse.dart';
import 'package:smart_app_test/features/auth/data/dto/send_otp_response_dto.dart';

void main() {
  group('SendOtpResponseDto.fromJson', () {
    test('parses a delivered-OTP body', () {
      final dto = SendOtpResponseDto.fromJson({
        'delivery': 'wa',
        'expires_in': 300,
      });
      expect(dto.delivery, 'wa');
      expect(dto.expiresIn, 300);
      expect(dto.alreadyVerified, isFalse);
    });

    test('parses an already-verified short-circuit body', () {
      final dto = SendOtpResponseDto.fromJson({'verified': true});
      expect(dto.delivery, isNull);
      expect(dto.expiresIn, isNull);
      expect(dto.alreadyVerified, isTrue);
    });

    test('accepts numeric-string expires_in', () {
      final dto = SendOtpResponseDto.fromJson({'expires_in': '300'});
      expect(dto.expiresIn, 300);
    });

    test('rejects a non-bool verified field', () {
      expect(
        () => SendOtpResponseDto.fromJson({'verified': 'yes'}),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.field, 'field', 'verified')),
      );
    });
  });
}

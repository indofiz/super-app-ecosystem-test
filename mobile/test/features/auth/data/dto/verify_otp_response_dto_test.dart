import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/core/network/bff_parse.dart';
import 'package:smart_app_test/features/auth/data/dto/verify_otp_response_dto.dart';

void main() {
  group('VerifyOtpResponseDto.fromJson', () {
    test('parses a complete body', () {
      final dto = VerifyOtpResponseDto.fromJson({
        'access_token': 'tok',
        'session_id': 'sid',
        'expires_in': 3600,
      });
      expect(dto.accessToken, 'tok');
      expect(dto.sessionId, 'sid');
      expect(dto.expiresIn, 3600);
    });

    test('throws when session_id is missing (stricter than refresh)', () {
      expect(
        () => VerifyOtpResponseDto.fromJson({
          'access_token': 'tok',
          'expires_in': 3600,
        }),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.field, 'field', 'session_id')
            .having((e) => e.reason, 'reason', 'missing')),
      );
    });

    test('throws when access_token is missing', () {
      expect(
        () => VerifyOtpResponseDto.fromJson({
          'session_id': 'sid',
          'expires_in': 3600,
        }),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.field, 'field', 'access_token')),
      );
    });
  });
}

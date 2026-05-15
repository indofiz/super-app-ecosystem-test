import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/core/network/bff_parse.dart';
import 'package:smart_app_test/features/auth/data/dto/refresh_response_dto.dart';

void main() {
  group('RefreshResponseDto.fromJson', () {
    test('parses a complete body', () {
      final dto = RefreshResponseDto.fromJson({
        'access_token': 'tok',
        'session_id': 'sid',
        'expires_in': 3600,
      });
      expect(dto.accessToken, 'tok');
      expect(dto.sessionId, 'sid');
      expect(dto.expiresIn, 3600);
    });

    test('accepts a numeric-string expires_in', () {
      final dto = RefreshResponseDto.fromJson({
        'access_token': 'tok',
        'expires_in': '3600',
      });
      expect(dto.expiresIn, 3600);
    });

    test('treats session_id as optional', () {
      final dto = RefreshResponseDto.fromJson({
        'access_token': 'tok',
        'expires_in': 3600,
      });
      expect(dto.sessionId, isNull);
    });

    test('throws when access_token is missing', () {
      expect(
        () => RefreshResponseDto.fromJson({'expires_in': 3600}),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.field, 'field', 'access_token')
            .having((e) => e.reason, 'reason', 'missing')),
      );
    });

    test('throws when expires_in is missing', () {
      expect(
        () => RefreshResponseDto.fromJson({'access_token': 'tok'}),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.field, 'field', 'expires_in')
            .having((e) => e.reason, 'reason', 'missing')),
      );
    });

    test('throws when expires_in has the wrong type', () {
      expect(
        () => RefreshResponseDto.fromJson({
          'access_token': 'tok',
          'expires_in': true,
        }),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.reason, 'reason', 'wrong-type:int')),
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/core/network/bff_parse.dart';
import 'package:smart_app_test/features/auth/data/dto/me_response_dto.dart';

void main() {
  group('MeResponseDto.fromJson', () {
    test('parses a complete body', () {
      final dto = MeResponseDto.fromJson({
        'sub': 'u-1',
        'username': 'tata',
        'email': 'tata@pangkalpinang.go.id',
        'emailVerified': true,
        'phoneNumber': '+6281234567890',
        'phoneNumberVerified': false,
        'roles': ['citizen', 'admin'],
        'expiresAt': '2030-01-01T00:00:00Z',
      });
      expect(dto.sub, 'u-1');
      expect(dto.username, 'tata');
      expect(dto.email, 'tata@pangkalpinang.go.id');
      expect(dto.emailVerified, isTrue);
      expect(dto.phoneNumber, '+6281234567890');
      expect(dto.phoneNumberVerified, isFalse);
      expect(dto.roles, ['citizen', 'admin']);
      expect(dto.expiresAt, DateTime.utc(2030, 1, 1));
    });

    test('treats sub as empty when missing (existing behaviour)', () {
      final dto = MeResponseDto.fromJson({'roles': <String>[]});
      expect(dto.sub, '');
    });

    test('defaults verification flags to false when absent', () {
      final dto = MeResponseDto.fromJson({'sub': 'u'});
      expect(dto.emailVerified, isFalse);
      expect(dto.phoneNumberVerified, isFalse);
    });

    test('eagerly rejects non-String elements in roles (audit-002 L-04)', () {
      expect(
        () => MeResponseDto.fromJson({
          'sub': 'u',
          'roles': ['citizen', 42],
        }),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.field, 'field', 'roles')
            .having((e) => e.reason, 'reason', 'wrong-type:List<String>')),
      );
    });

    test('rejects a roles value that is not a List', () {
      expect(
        () => MeResponseDto.fromJson({'sub': 'u', 'roles': 'admin'}),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.field, 'field', 'roles')),
      );
    });

    test('leaves expiresAt null on unparseable timestamps', () {
      final dto = MeResponseDto.fromJson({
        'sub': 'u',
        'expiresAt': 'not-a-date',
      });
      expect(dto.expiresAt, isNull);
    });

    test('rejects a non-String expiresAt', () {
      expect(
        () => MeResponseDto.fromJson({'sub': 'u', 'expiresAt': 12345}),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.field, 'field', 'expiresAt')),
      );
    });
  });
}

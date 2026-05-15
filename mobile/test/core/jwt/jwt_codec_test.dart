import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/core/jwt/jwt_codec.dart';

void main() {
  group('encodeJwtSegment / decodeJwtSegment', () {
    test('round-trips a typical claims map', () {
      final claims = <String, dynamic>{
        'sub': 'user-123',
        'email': 'a@b.test',
        'email_verified': true,
        'roles': ['citizen', 'admin'],
        'nested': {'foo': 1, 'bar': null},
      };
      final segment = encodeJwtSegment(claims);
      expect(segment.contains('='), isFalse, reason: 'segment must be unpadded');
      expect(decodeJwtSegment(segment), claims);
    });

    test('decodes regardless of original length mod 4', () {
      for (var pad = 0; pad < 3; pad++) {
        final claims = {'k': 'x' * pad};
        final segment = encodeJwtSegment(claims);
        expect(decodeJwtSegment(segment), claims,
            reason: 'mod=${segment.length % 4} should decode');
      }
    });

    test('returns null on empty input', () {
      expect(decodeJwtSegment(''), isNull);
    });

    test('returns null when segment length mod 4 == 1 (illegal base64)', () {
      expect(decodeJwtSegment('abcde'), isNull);
    });

    test('returns null on non-base64 input', () {
      expect(decodeJwtSegment('!!!not-base64!!!'), isNull);
    });

    test('returns null when decoded payload is not a JSON object', () {
      final arraySegment =
          base64Url.encode(utf8.encode('[1,2,3]')).replaceAll('=', '');
      expect(decodeJwtSegment(arraySegment), isNull);
    });

    test('returns null when decoded bytes are not valid utf8 JSON', () {
      final garbage = base64Url.encode([0xff, 0xfe, 0xfd]).replaceAll('=', '');
      expect(decodeJwtSegment(garbage), isNull);
    });
  });
}

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/core/network/bff_parse.dart';

Response<Map<String, dynamic>> _res(Map<String, dynamic>? body) {
  return Response<Map<String, dynamic>>(
    requestOptions: RequestOptions(path: '/x'),
    statusCode: 200,
    data: body,
  );
}

void main() {
  group('requireBody', () {
    test('returns the body when non-empty', () {
      final body = requireBody(_res({'k': 1}), '/x');
      expect(body, {'k': 1});
    });

    test('throws on null body', () {
      expect(
        () => requireBody(_res(null), '/x'),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.field, 'field', '<body>')
            .having((e) => e.reason, 'reason', 'empty-body')),
      );
    });

    test('throws on empty body', () {
      expect(
        () => requireBody(_res(const {}), '/x'),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.reason, 'reason', 'empty-body')),
      );
    });
  });

  group('requireString', () {
    test('returns the value when present and a String', () {
      expect(requireString({'k': 'v'}, 'k'), 'v');
    });

    test('throws missing when the key is absent', () {
      expect(
        () => requireString({}, 'k'),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.reason, 'reason', 'missing')),
      );
    });

    test('throws missing when the value is null', () {
      expect(
        () => requireString({'k': null}, 'k'),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.reason, 'reason', 'missing')),
      );
    });

    test('throws wrong-type when the value is not a String', () {
      expect(
        () => requireString({'k': 42}, 'k'),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.reason, 'reason', 'wrong-type:String')),
      );
    });
  });

  group('requireInt', () {
    test('accepts an int', () {
      expect(requireInt({'k': 7}, 'k'), 7);
    });

    test('accepts a double (truncates)', () {
      expect(requireInt({'k': 7.9}, 'k'), 7);
    });

    test('accepts a numeric String (audit-002 C-01 coercion case)', () {
      expect(requireInt({'k': '3600'}, 'k'), 3600);
    });

    test('throws missing when absent', () {
      expect(
        () => requireInt({}, 'k'),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.reason, 'reason', 'missing')),
      );
    });

    test('throws wrong-type on a non-numeric String', () {
      expect(
        () => requireInt({'k': 'soon'}, 'k'),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.reason, 'reason', 'wrong-type:int')),
      );
    });

    test('throws wrong-type on a non-numeric, non-String value', () {
      expect(
        () => requireInt({'k': true}, 'k'),
        throwsA(isA<BffParseFailure>()
            .having((e) => e.reason, 'reason', 'wrong-type:int')),
      );
    });
  });

  group('optionalString / optionalInt / optionalBool', () {
    test('return null/fallback when absent', () {
      expect(optionalString({}, 'k'), isNull);
      expect(optionalInt({}, 'k'), isNull);
      expect(optionalBool({}, 'k'), isFalse);
      expect(optionalBool({}, 'k', fallback: true), isTrue);
    });

    test('return parsed value when present and correctly typed', () {
      expect(optionalString({'k': 'v'}, 'k'), 'v');
      expect(optionalInt({'k': '12'}, 'k'), 12);
      expect(optionalBool({'k': true}, 'k'), isTrue);
    });

    test('throw on wrong type even when optional', () {
      expect(
        () => optionalString({'k': 1}, 'k'),
        throwsA(isA<BffParseFailure>()),
      );
      expect(
        () => optionalInt({'k': false}, 'k'),
        throwsA(isA<BffParseFailure>()),
      );
      expect(
        () => optionalBool({'k': 1}, 'k'),
        throwsA(isA<BffParseFailure>()),
      );
    });
  });
}

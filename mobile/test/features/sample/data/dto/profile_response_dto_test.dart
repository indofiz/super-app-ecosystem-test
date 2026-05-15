import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/features/sample/data/dto/profile_response_dto.dart';

void main() {
  group('ProfileResponseDto.fromJson', () {
    test('preserves the raw body for dev-dashboard inspection', () {
      final dto = ProfileResponseDto.fromJson({
        'sub': 'u-1',
        'extras': {'level': 1, 'tags': ['citizen']},
      });
      expect(dto.raw['sub'], 'u-1');
      expect((dto.raw['extras'] as Map)['level'], 1);
    });

    test('raw map is unmodifiable so callers cannot mutate shared state', () {
      final dto = ProfileResponseDto.fromJson({'sub': 'u'});
      expect(() => dto.raw['injected'] = 'x', throwsUnsupportedError);
    });
  });
}

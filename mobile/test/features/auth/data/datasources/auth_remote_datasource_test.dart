import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:smart_app_test/features/auth/data/bff_auth_api.dart';
import 'package:smart_app_test/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:smart_app_test/features/auth/data/dto/me_response_dto.dart';
import 'package:smart_app_test/features/auth/data/dto/refresh_response_dto.dart';

class _MockBffAuthApi extends Mock implements BffAuthApi {}

void main() {
  late _MockBffAuthApi api;
  late AuthRemoteDataSource remote;

  setUp(() {
    api = _MockBffAuthApi();
    remote = AuthRemoteDataSource(api: api);
  });

  test('refresh threads sessionId/bearer through to the API', () async {
    const dto = RefreshResponseDto(accessToken: 'tok', expiresIn: 3600);
    when(() => api.refresh(sessionId: 'sid', bearer: 'b'))
        .thenAnswer((_) async => dto);

    final result = await remote.refresh(sessionId: 'sid', bearer: 'b');
    expect(result, same(dto));
    verify(() => api.refresh(sessionId: 'sid', bearer: 'b')).called(1);
  });

  test('getMe threads bearer through to the API', () async {
    const dto = MeResponseDto(sub: 'u', roles: []);
    when(() => api.getMe('b')).thenAnswer((_) async => dto);

    final result = await remote.getMe(bearer: 'b');
    expect(result, same(dto));
    verify(() => api.getMe('b')).called(1);
  });

  test('logout threads sessionId/bearer through to the API', () async {
    when(() => api.logout(sessionId: 'sid', bearer: 'b'))
        .thenAnswer((_) async {});

    await remote.logout(sessionId: 'sid', bearer: 'b');
    verify(() => api.logout(sessionId: 'sid', bearer: 'b')).called(1);
  });

  test('dispose disposes the underlying API', () async {
    when(api.dispose).thenAnswer((_) async {});

    await remote.dispose();
    verify(api.dispose).called(1);
  });
}

import 'package:dio/dio.dart';

import '../bff_auth_api.dart';
import '../dto/me_response_dto.dart';
import '../dto/refresh_response_dto.dart';

/// Remote data source for the auth feature (audit-002 H-01).
///
/// Wraps [BffAuthApi] so repositories depend on a data-source abstraction
/// rather than on the HTTP wire detail. Stateless: callers pass the
/// bearer / session_id explicitly. The repo holds the local data source
/// and pipes the persisted values through here — that keeps "where the
/// token comes from" in one place (the repo's orchestration) while the
/// HTTP shape lives entirely behind this class.
///
/// Every method accepts an optional [CancelToken] (audit-002 H-02). The
/// repo plumbs it from the bloc; cancelling aborts the in-flight HTTP
/// request, and the data layer translates Dio's cancel exception into a
/// domain `CancelledException` so the bloc doesn't need to know about
/// Dio.
///
/// Owns the underlying [BffAuthApi] (constructed externally) and disposes
/// it on [dispose].
class AuthRemoteDataSource {
  AuthRemoteDataSource({required BffAuthApi api}) : _api = api;

  final BffAuthApi _api;

  Future<RefreshResponseDto> refresh({
    required String sessionId,
    required String bearer,
    CancelToken? cancel,
  }) =>
      _api.refresh(sessionId: sessionId, bearer: bearer, cancel: cancel);

  Future<MeResponseDto> getMe({
    required String bearer,
    CancelToken? cancel,
  }) =>
      _api.getMe(bearer, cancel: cancel);

  Future<void> logout({
    required String sessionId,
    required String bearer,
    CancelToken? cancel,
  }) =>
      _api.logout(sessionId: sessionId, bearer: bearer, cancel: cancel);

  Future<void> dispose() => _api.dispose();
}

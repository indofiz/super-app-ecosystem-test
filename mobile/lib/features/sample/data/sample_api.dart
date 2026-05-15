import 'package:dio/dio.dart';

import '../../../core/network/api_failure.dart';
import '../../../core/network/bff_parse.dart';
import '../../../core/network/cancelled_exception.dart';
import 'dto/profile_response_dto.dart';

/// HTTP client for `/api/*` services that sit behind Kong.
///
/// Takes the workspace-shared [Dio] from [ApiClient], which already injects
/// the bearer and retries on 401. Features should never see the access
/// token directly.
///
/// Error contract (audit-002 C-02): every `DioException` is translated to
/// an [ApiFailure] before it leaves this class, so the UI never sees a
/// stringified `DioException` (which would otherwise leak the request URL,
/// headers, and response body into rendered error text). Parse failures
/// from contract drift also surface as [ApiFailure].
///
/// Return contract (audit-002 H-03): returns a typed DTO instead of a
/// raw `Map<String, dynamic>`. The DTO preserves the raw body so the
/// dev dashboard can still pretty-print upstream responses for hand
/// inspection; real consumers should pull typed fields off the DTO as
/// they ship.
class SampleApi {
  SampleApi({required Dio dio}) : _dio = dio;

  final Dio _dio;

  /// Calls `/api/profile` (Kong-protected). Useful for proving the chain
  /// `mobile → nginx → Kong → service` works end-to-end.
  ///
  /// Accepts an optional [cancel] token (audit-002 H-02) — callers
  /// (e.g. the dev dashboard) cancel on widget dispose so the in-flight
  /// HTTP request gets aborted and the response can't `setState` on an
  /// unmounted widget. A cancelled call surfaces as a `CancelledException`,
  /// which callers typically ignore.
  Future<ProfileResponseDto> getProfile({CancelToken? cancel}) =>
      withCancelTranslation(() async {
        try {
          final res = await _dio.get<Map<String, dynamic>>(
            '/api/profile',
            cancelToken: cancel,
          );
          return ProfileResponseDto.fromJson(
            requireBody(res, '/api/profile'),
          );
        } on DioException catch (e) {
          throw mapDioToApiFailure(e);
        } on BffParseFailure catch (e) {
          throw mapParseToApiFailure(e);
        }
      });
}

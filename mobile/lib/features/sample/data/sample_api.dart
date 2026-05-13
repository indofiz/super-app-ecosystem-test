import 'package:dio/dio.dart';

/// HTTP client for `/api/*` services that sit behind Kong.
///
/// Takes the workspace-shared [Dio] from [ApiClient], which already injects
/// the bearer and retries on 401. Features should never see the access
/// token directly.
class SampleApi {
  SampleApi({required Dio dio}) : _dio = dio;

  final Dio _dio;

  /// Calls `/api/profile` (Kong-protected). Useful for proving the chain
  /// `mobile → nginx → Kong → service` works end-to-end.
  Future<Map<String, dynamic>> getProfile() async {
    final res = await _dio.get<Map<String, dynamic>>('/api/profile');
    return res.data ?? const {};
  }
}

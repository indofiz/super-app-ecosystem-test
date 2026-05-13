import 'package:dio/dio.dart';

import '../../../core/config/app_config.dart';

/// HTTP client for `/api/*` services that sit behind Kong.
///
/// In dev: nginx → Kong → sample-service. The bearer is the BFF-issued
/// internal JWT held by the auth repository. We pass it explicitly here
/// because this client has no knowledge of the auth state.
class SampleApi {
  SampleApi({required this.config, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: config.bffBaseUrl,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
            ));

  final AppConfig config;
  final Dio _dio;

  /// Calls `/api/profile` (Kong-protected). Returns whatever the
  /// sample-service responded with — useful for proving the chain works.
  Future<Map<String, dynamic>> getProfile(String bearer) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/api/profile',
      options: Options(headers: {'Authorization': 'Bearer $bearer'}),
    );
    return res.data ?? const {};
  }
}

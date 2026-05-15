import 'package:dio/dio.dart';

import '../config/app_config.dart';

/// Default HTTP timeouts for all BFF/Kong calls.
///
/// Kept here so the auth and `/api/*` stacks share the same contract.
/// If you change one, you almost certainly mean to change both — and the
/// next reviewer can audit the timing budget in one place.
const Duration kHttpConnectTimeout = Duration(seconds: 10);
const Duration kHttpReceiveTimeout = Duration(seconds: 15);

/// Constructs a [Dio] with the timeouts and base URL every HTTP call in this
/// app shares. Interceptors (auth, refresh, logging) are deliberately NOT
/// attached here — each caller layers on what it needs.
///
/// Pass [extraHeaders] for client-wide defaults like `Content-Type`. Per-call
/// headers should be set via `Options(headers: ...)` at the call site.
Dio createDio({
  required AppConfig config,
  Map<String, String>? extraHeaders,
}) {
  return Dio(
    BaseOptions(
      baseUrl: config.bffBaseUrl,
      connectTimeout: kHttpConnectTimeout,
      receiveTimeout: kHttpReceiveTimeout,
      headers: extraHeaders,
    ),
  );
}

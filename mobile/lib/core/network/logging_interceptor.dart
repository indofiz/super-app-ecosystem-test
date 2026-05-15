import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../logging/auth_log.dart';

/// Returns a Dio interceptor that emits `→ / ← / ✗` lines through
/// [authLog] under the supplied [tag]. No-op in release builds because
/// [authLog] short-circuits when `kDebugMode` is false.
///
/// SECURITY: do NOT log request bodies, headers, or any part of the
/// bearer. By default, response bodies are also omitted; opt in with
/// [logErrorBody] only for endpoints whose error envelopes are safe
/// (e.g. the BFF auth `{error, error_description, detail}` shape).
Interceptor httpLoggingInterceptor(
  String tag, {
  bool logErrorBody = false,
}) {
  return InterceptorsWrapper(
    onRequest: (o, h) {
      if (kDebugMode) authLog(tag, '→ ${o.method} ${o.uri}');
      h.next(o);
    },
    onResponse: (r, h) {
      if (kDebugMode) {
        authLog(tag, '← ${r.statusCode} ${r.requestOptions.uri}');
      }
      h.next(r);
    },
    onError: (e, h) {
      if (kDebugMode) {
        authLog(
          tag,
          '✗ ${e.requestOptions.method} ${e.requestOptions.uri} — ${e.response?.statusCode} ${e.message}',
        );
        if (logErrorBody && e.response?.data != null) {
          authLog(tag, '  body=${e.response!.data}');
        }
      }
      h.next(e);
    },
  );
}

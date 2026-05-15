import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../logging/auth_log.dart';

/// Returns a Dio interceptor that emits `→ / ← / ✗` lines through
/// [authLog] under the supplied [tag]. No-op in release builds because
/// [authLog] short-circuits when `kDebugMode` is false.
///
/// SECURITY: do NOT log request bodies, headers, or any part of the
/// bearer. Response bodies are also never logged whole — even on errors.
///
/// On failures, set [logBffErrorEnvelope] to surface the BFF's
/// `{error, detail.attempts_left}` discriminator fields only. The
/// `error_description` field is deliberately omitted (audit-004 H-03):
/// for verify-OTP errors the BFF echoes user input into it, which leaks
/// to `adb logcat` on QA devices and to any app holding `READ_LOGS` on a
/// rooted handset.
Interceptor httpLoggingInterceptor(
  String tag, {
  bool logBffErrorEnvelope = false,
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
        // audit-004 M-04: SEVERE (1000) so the `✗` line surfaces in the
        // logcat ERROR bucket and in DevTools' filtered views, separable
        // from the INFO-level → / ← trace lines.
        authLog(
          tag,
          '✗ ${e.requestOptions.method} ${e.requestOptions.uri} — ${e.response?.statusCode} ${e.message}',
          level: 1000,
        );
        if (logBffErrorEnvelope) {
          final body = e.response?.data;
          if (body is Map) {
            final code = body['error'] ?? '<no-error-code>';
            final detail = body['detail'];
            final attempts =
                (detail is Map) ? detail['attempts_left'] : null;
            authLog(
              tag,
              '  envelope: error=$code'
              '${attempts != null ? ' attempts_left=$attempts' : ''}',
              level: 1000,
            );
          }
        }
      }
      h.next(e);
    },
  );
}

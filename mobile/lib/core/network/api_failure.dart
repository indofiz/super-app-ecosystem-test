import 'package:dio/dio.dart';

import 'bff_error.dart';
import 'bff_parse.dart';
import 'cancelled_exception.dart';

/// Closed enumeration of `/api/*` (Kong-side) failures.
///
/// Same contract as `AuthErrorCode` / `VerificationErrorCode`: the data
/// layer emits the code, the presentation layer resolves it via
/// [AppLocalizations]. The `/api/*` surface today is the dev dashboard
/// only — but `ApiFailure` is the template every future Kong-side
/// repository inherits, so the code set is closed even though only a
/// subset is rendered.
enum ApiErrorCode {
  /// Connect/receive/send timeout or `connectionError` (DNS, TCP reset,
  /// captive portal). Retryable.
  network,

  /// 5xx from Kong / upstream. Retryable (server-side blip, not the
  /// client's input).
  server,

  /// 401 propagated past the refresh-on-401 interceptor — i.e. refresh
  /// itself failed too. Caller should bounce to login.
  unauthorized,

  /// 403 — Kong-side authorization said no even with a valid bearer.
  forbidden,

  /// 404.
  notFound,

  /// Any other 4xx.
  badRequest,

  /// Response body violated its contract (missing key / wrong type /
  /// empty body). Distinct from `server` so the UI can hint "client out
  /// of date" if needed.
  parse,

  /// Catch-all for anything else.
  unknown,
}

class ApiFailure implements Exception {
  ApiFailure({
    required this.code,
    this.diagnostic,
    this.cause,
    this.retryable = false,
  });

  final ApiErrorCode code;

  /// Raw `error_description` or parse-failure detail. Logs only — never
  /// user-facing copy (same rule as `AuthFailure.diagnostic`).
  final String? diagnostic;

  final Object? cause;
  final bool retryable;

  @override
  String toString() =>
      'ApiFailure(code: $code${diagnostic != null ? ', diagnostic: $diagnostic' : ''})';
}

/// Map a [DioException] to a typed [ApiFailure].
///
/// Cancellation is NOT a failure mode — callers should wrap the network
/// call in `withCancelTranslation` so `DioException(type: cancel)`
/// becomes a domain [CancelledException] before this mapper sees it.
/// If a cancel slips through anyway, this mapper still re-throws as
/// [CancelledException] (defence in depth — audit-002 H-02).
///
/// Reuses `describeBffError` to keep envelope decoding in one place
/// — the Kong-side services share the BFF's `{error, error_description}`
/// shape per the platform plan, so the envelope reader is shared even
/// though the failure types are not.
ApiFailure mapDioToApiFailure(
  DioException e, {
  ApiErrorCode fallback = ApiErrorCode.unknown,
}) {
  if (e.type == DioExceptionType.cancel) {
    throw const CancelledException();
  }
  if (e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.receiveTimeout ||
      e.type == DioExceptionType.sendTimeout ||
      e.type == DioExceptionType.connectionError) {
    final info = describeBffError(e);
    return ApiFailure(
      code: ApiErrorCode.network,
      diagnostic: info.errorDescription,
      cause: e,
      retryable: true,
    );
  }

  final info = describeBffError(e);
  final status = info.statusCode;
  final code = _codeForStatus(status, fallback);
  return ApiFailure(
    code: code,
    diagnostic: info.errorDescription,
    cause: e,
    retryable: code == ApiErrorCode.server,
  );
}

/// Map a [BffParseFailure] thrown by `requireBody` / `requireString` etc.
/// into the `/api/*` failure type. Convenience for call sites that
/// stack `on DioException` / `on BffParseFailure` arms.
ApiFailure mapParseToApiFailure(BffParseFailure e) {
  return ApiFailure(
    code: ApiErrorCode.parse,
    diagnostic: '$e',
    cause: e,
  );
}

ApiErrorCode _codeForStatus(int? status, ApiErrorCode fallback) {
  if (status == null) return fallback;
  if (status == 401) return ApiErrorCode.unauthorized;
  if (status == 403) return ApiErrorCode.forbidden;
  if (status == 404) return ApiErrorCode.notFound;
  if (status >= 500) return ApiErrorCode.server;
  if (status >= 400) return ApiErrorCode.badRequest;
  return fallback;
}

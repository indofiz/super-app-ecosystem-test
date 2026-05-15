import 'package:dio/dio.dart';

/// Parsed view of a Dio failure against the BFF.
///
/// The BFF's error middleware projects every error as
/// `{error, error_description, detail}`. Some endpoints (verify-OTP) put
/// `attempts_left` inside `detail`. Transport-level failures (timeouts,
/// connection drops) have no response body — `isTimeout` is the signal.
///
/// This is the *parsed shape* of an error. Mapping it to a typed domain
/// failure (e.g. `AuthFailure` / `VerificationFailure`) is each feature's
/// job — the failure types and code enums are feature-specific, but the
/// wire-level envelope is shared and lives here.
class BffErrorInfo {
  const BffErrorInfo({
    required this.statusCode,
    required this.isTimeout,
    this.errorDescription,
    this.attemptsLeft,
  });

  /// HTTP status, or null for transport-level errors (no response).
  final int? statusCode;

  /// True iff this is a Dio connect/receive/send timeout. Indicates the
  /// failure is retryable and not the server's fault.
  final bool isTimeout;

  /// The BFF's `error_description` field. SECURITY: this is for
  /// diagnostic logs only — feature code MUST NOT surface it as
  /// user-visible copy.
  final String? errorDescription;

  /// Server-reported `detail.attempts_left` (verify-OTP endpoints).
  /// Null on any other endpoint or when the BFF omits it.
  final int? attemptsLeft;
}

/// Parse a [DioException] into the BFF's error envelope shape.
///
/// Pure: does not throw, does not allocate domain failures. Each feature
/// calls this and then constructs its own typed failure from the result.
BffErrorInfo describeBffError(DioException e) {
  String? desc;
  int? attemptsLeft;
  final body = e.response?.data;
  if (body is Map) {
    if (body['error_description'] is String) {
      desc = body['error_description'] as String;
    }
    final detail = body['detail'];
    if (detail is Map && detail['attempts_left'] is num) {
      attemptsLeft = (detail['attempts_left'] as num).toInt();
    }
  }
  final isTimeout = e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.receiveTimeout ||
      e.type == DioExceptionType.sendTimeout;
  return BffErrorInfo(
    statusCode: e.response?.statusCode,
    isTimeout: isTimeout,
    errorDescription: desc,
    attemptsLeft: attemptsLeft,
  );
}

import 'package:dio/dio.dart';

import '../config/app_config.dart';
import 'pinned_http_adapter.dart';
import 'retry_interceptor.dart';

/// Default HTTP timeouts for all BFF/Kong calls.
///
/// Kept here so the auth and `/api/*` stacks share the same contract.
/// If you change one, you almost certainly mean to change both — and the
/// next reviewer can audit the timing budget in one place.
///
/// `kHttpSendTimeout` matches `kHttpReceiveTimeout` (audit-002 M-03 —
/// without a send-timeout, the data layer's `sendTimeout` retry branch
/// would never fire, leaving slow-upload stalls (e.g. an OTP submitted
/// over 2G + captive portal) effectively un-bounded).
const Duration kHttpConnectTimeout = Duration(seconds: 10);
const Duration kHttpReceiveTimeout = Duration(seconds: 15);
const Duration kHttpSendTimeout = Duration(seconds: 15);

/// audit-004 M-03: long-running endpoints — specifically
/// `/auth/{email,phone}/send-otp` — synchronously dispatch to Fonnte
/// (WhatsApp) / SMTP and only return after the third-party hands back a
/// delivery receipt. Fonnte's documented p95 is 6-8 s with p99 > 20 s
/// during regional carrier saturation, so a 15 s receive cap would abort
/// the client while the BFF and Fonnte are still completing the delivery
/// — the user sees "Gagal mengirim OTP" while the OTP buzzes on their
/// phone. Per-call timeout override via `Options(receiveTimeout: …)`.
const Duration kHttpReceiveTimeoutSlow = Duration(seconds: 30);

/// Constructs a [Dio] with the timeouts and base URL every HTTP call in this
/// app shares. Interceptors (auth, refresh, logging) are deliberately NOT
/// attached here — each caller layers on what it needs.
///
/// Pass [extraHeaders] for client-wide defaults like `Content-Type`. Per-call
/// headers should be set via `Options(headers: ...)` at the call site.
///
/// Pass [withRetry] to install a [RetryInterceptor] (audit-002 H-04). All
/// three Dio stacks in the app opt in — the interceptor only triggers on
/// transient errors (timeouts, connectionError, 502/503/504), and
/// individual mutating call sites (e.g. verify-OTP) skip it via the
/// per-request `noRetry` extra.
Dio createDio({
  required AppConfig config,
  Map<String, String>? extraHeaders,
  bool withRetry = false,
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: config.bffBaseUrl,
      connectTimeout: kHttpConnectTimeout,
      receiveTimeout: kHttpReceiveTimeout,
      sendTimeout: kHttpSendTimeout,
      headers: extraHeaders,
    ),
  );
  if (withRetry) {
    dio.interceptors.add(RetryInterceptor(dio: dio));
  }
  // Install SPKI-hash pinning adapter when BFF_CERT_SHA256 is supplied at
  // build time (release builds only). Returns null in debug / when no hash.
  final pinnedAdapter = buildPinnedAdapter();
  if (pinnedAdapter != null) {
    dio.httpClientAdapter = pinnedAdapter;
  }
  return dio;
}

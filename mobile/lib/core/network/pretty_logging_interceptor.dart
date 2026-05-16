import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';

import '../config/app_config.dart';
import '../logging/auth_log.dart';

/// Returns a boxed, multi-line pretty HTTP logger for dev — or `null` when
/// it must not run. Callers add it to `dio.interceptors` only when non-null,
/// so in release builds the whole feature tree-shakes away.
///
/// Enabled iff `kDebugMode && config.httpVerboseLog`. `kReleaseMode`
/// already forces `httpVerboseLog=false` in [AppConfig.fromEnv], so the
/// `kDebugMode` guard here is belt-and-braces (and lets a profile build
/// opt in without the logger leaking into release).
///
/// SECURITY (audit-004 H-03): this logger prints request/response bodies,
/// headers and query params VERBATIM — the bearer & refresh tokens, the
/// user's typed OTP `code` and the phone number are shown in full so they
/// can be read straight off the console while debugging. There is NO
/// field-level redaction. This is acceptable *only* because the logger can
/// never run in a release build: H-03 now rests entirely on the
/// `httpVerboseLog=false` release gate in [AppConfig.fromEnv]. Never enable
/// `httpVerboseLog` on a build that reaches real users.
Interceptor? prettyHttpLoggingInterceptor(
  AppConfig config, {
  @visibleForTesting void Function(Object line)? debugSink,
}) {
  if (!kDebugMode || !config.httpVerboseLog) return null;
  return PrettyDioLogger(
    requestHeader: true,
    requestBody: true,
    responseBody: true,
    responseHeader: false,
    error: true,
    compact: true,
    // One call per line. Production routes it through the dart:developer
    // pipeline (tagged `verbose` so DevTools can filter it apart from the
    // terse `→/←/✗` logger); tests pass a capturing sink.
    logPrint: debugSink ?? _printVerbose,
  );
}

void _printVerbose(Object o) => authLog('verbose', o.toString());

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Debug-only logger used by the auth stack. Centralised so prefixes stay
/// consistent and so a future swap to a real logging package is one edit.
///
/// SECURITY: never pass raw tokens, session_ids, or any bearer to this. The
/// auth files truncate before calling — keep it that way.
///
/// audit-004 M-04: routes through `dart:developer.log` instead of `print`.
/// Three things change in practice:
///   1. Severity: `level` is honoured by DevTools and by `adb logcat`
///      filters (`logcat *:E` now picks up our error lines). Default is
///      `800` (INFO); pass `1000` for SEVERE.
///   2. Structured `error` + `stackTrace` parameters integrate with the
///      DevTools logging view; a future crash reporter (C-02) reads them.
///   3. Flush semantics: `developer.log` writes through the VM service,
///      so the last log lines before an uncaught exception are not lost
///      to stdout buffering the way `print` would lose them.
///
/// Still gated on `kDebugMode` — the auth log channel is dev/QA only.
/// Anything that needs to reach production telemetry goes through
/// `ErrorReporter` (audit-004 C-01).
void authLog(
  String tag,
  String msg, {
  int level = 800,
  Object? error,
  StackTrace? stackTrace,
}) {
  if (!kDebugMode) return;
  developer.log(
    msg,
    name: 'AUTH.$tag',
    level: level,
    error: error,
    stackTrace: stackTrace,
  );
}

/// Returns a closure that prefixes every message with [tag]. Lets each
/// file keep `_log('foo')` ergonomics without redeclaring the same
/// one-line helper.
void Function(String msg) authLogger(String tag) =>
    (msg) => authLog(tag, msg);

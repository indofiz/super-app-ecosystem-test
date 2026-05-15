import 'dart:collection';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Single sink for uncaught errors across the app.
///
/// All four global pipes (`FlutterError.onError`,
/// `PlatformDispatcher.instance.onError`, `runZonedGuarded`,
/// `Isolate.current.addErrorListener`) and `ErrorWidget.builder` forward
/// here. When a real crash reporter (Sentry / Crashlytics / Datadog) is
/// added later, only this file changes — call sites stay identical.
///
/// SECURITY: in release builds, only `runtimeType` + a sanitised hint is
/// recorded. In debug, the full `error.toString()` + stack are logged via
/// `dart:developer.log` so they appear in DevTools.
class ErrorReporter {
  ErrorReporter._();

  static ErrorReporter _instance = ErrorReporter._();
  static ErrorReporter get instance => _instance;

  @visibleForTesting
  static set instance(ErrorReporter value) => _instance = value;

  static const int _ringCapacity = 20;
  final Queue<ReportedError> _ring = Queue<ReportedError>();

  /// Most recent errors first. Capped at 20 entries.
  List<ReportedError> get recent => _ring.toList(growable: false);

  void reportFlutterError(FlutterErrorDetails details) {
    _record(
      error: details.exception,
      stack: details.stack,
      context: 'flutter:${details.library ?? "framework"}',
      fatal: false,
    );
    // Preserve default debug presentation (red box + console dump).
    FlutterError.presentError(details);
  }

  void reportError(
    Object error,
    StackTrace? stack, {
    String? context,
    bool fatal = false,
  }) {
    _record(error: error, stack: stack, context: context, fatal: fatal);
  }

  /// Special path for failures inside `main()` before `runApp` mounts the
  /// real UI tree. Separate so a future crash reporter can flag these as
  /// boot-blocking.
  void reportBootFailure(Object error, StackTrace? stack) {
    _record(
      error: error,
      stack: stack,
      context: 'boot',
      fatal: true,
    );
  }

  void _record({
    required Object error,
    required StackTrace? stack,
    required String? context,
    required bool fatal,
  }) {
    final entry = ReportedError(
      timestamp: DateTime.now(),
      errorType: error.runtimeType.toString(),
      message: kDebugMode ? error.toString() : _sanitise(error),
      context: context,
      fatal: fatal,
    );
    _ring.addLast(entry);
    while (_ring.length > _ringCapacity) {
      _ring.removeFirst();
    }
    developer.log(
      entry.message,
      name: context == null ? 'app.error' : 'app.error.$context',
      level: fatal ? 1200 : 1000,
      error: error,
      stackTrace: stack,
    );
  }

  /// Strips anything that might leak infra topology or user input.
  /// Default `DioException.toString()` embeds full URLs, headers, and a
  /// truncated response body — none of which belong in production logs
  /// surfaced via `flutter logs` on a tethered device.
  String _sanitise(Object error) {
    final type = error.runtimeType.toString();
    return type;
  }

  @visibleForTesting
  void clearForTest() => _ring.clear();
}

class ReportedError {
  const ReportedError({
    required this.timestamp,
    required this.errorType,
    required this.message,
    required this.context,
    required this.fatal,
  });

  final DateTime timestamp;
  final String errorType;
  final String message;
  final String? context;
  final bool fatal;
}

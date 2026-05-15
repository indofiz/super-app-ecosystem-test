import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app.dart';
import 'core/boot/boot_failure_app.dart';
import 'core/config/app_config.dart';
import 'core/http/api_client.dart';
import 'core/logging/error_reporter.dart';
import 'core/storage/secure_store.dart';
import 'features/auth/data/bff_auth_api.dart';
import 'features/auth/data/bff_auth_repository.dart';
import 'features/auth/data/datasources/auth_local_datasource.dart';
import 'features/auth/data/datasources/auth_remote_datasource.dart';
import 'features/auth/data/mock_auth_repository.dart';
import 'features/auth/domain/auth_repository.dart';
import 'features/verification/data/bff_verification_api.dart';
import 'features/verification/data/bff_verification_repository.dart';
import 'features/verification/data/datasources/verification_remote_datasource.dart';
import 'features/verification/data/mock_verification_repository.dart';
import 'features/verification/domain/verification_repository.dart';

void main() {
  // audit-004 C-01: wrap the entire startup + runApp in a guarded zone so
  // async errors raised anywhere in the app's root zone reach a single
  // sink. Pairs with FlutterError.onError, PlatformDispatcher.onError, and
  // the isolate error listener wired below.
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Framework errors: assertions inside build/layout/paint, errors
    // thrown from widget callbacks, gesture handler exceptions.
    FlutterError.onError = (details) {
      ErrorReporter.instance.reportFlutterError(details);
    };

    // Async errors from any zone that don't get caught by the
    // runZonedGuarded handler (e.g. unhandled Future.error from platform
    // channels). Returning true marks the error as handled.
    PlatformDispatcher.instance.onError = (error, stack) {
      ErrorReporter.instance.reportError(
        error,
        stack,
        context: 'platformDispatcher',
      );
      return true;
    };

    // Spawned-isolate errors. The main isolate's own errors flow through
    // runZonedGuarded; this is for any worker isolate the app spawns
    // later (e.g. image decoding, JSON parsing off the UI thread).
    Isolate.current.addErrorListener(
      RawReceivePort((dynamic pair) {
        final list = pair as List<dynamic>;
        final error = list[0];
        final stack = list[1];
        ErrorReporter.instance.reportError(
          error as Object,
          stack is StackTrace
              ? stack
              : (stack is String ? StackTrace.fromString(stack) : null),
          context: 'isolate',
          fatal: true,
        );
      }).sendPort,
    );

    await _bootstrap();
  }, (error, stack) {
    // audit-004 C-01: outermost catch-all. Anything that escapes the
    // handlers above lands here.
    ErrorReporter.instance.reportError(
      error,
      stack,
      context: 'zoneGuarded',
      fatal: true,
    );
  });
}

/// Performs dotenv load, config parse, and dependency wiring, then mounts
/// [SmartApp]. On any failure, mounts [BootFailureApp] instead so the user
/// sees an actionable screen instead of a black phone. Extracted so the
/// "Retry" button on [BootFailureApp] can re-invoke the same path.
Future<void> _bootstrap() async {
  try {
    await dotenv.load(fileName: '.env');

    final config = AppConfig.fromEnv();
    final secureStore = SecureStore();

    // Composition root — the one place that picks mock vs BFF and wires
    // the data-source layer (audit-002 H-01). `AuthLocalDataSource` is
    // shared between the auth + verification features: both read the
    // persisted bearer from the same source of truth.
    final authLocalDataSource =
        AuthLocalDataSource(secureStore: secureStore);

    final AuthRepository authRepository;
    final VerificationRepository verificationRepository;

    if (config.useMockAuth) {
      authRepository =
          MockAuthRepository(localDataSource: authLocalDataSource);
      verificationRepository = MockVerificationRepository(
        authRepository: authRepository,
        localDataSource: authLocalDataSource,
      );
    } else {
      final authRemoteDataSource = AuthRemoteDataSource(
        api: BffAuthApi(config: config),
      );
      final verificationRemoteDataSource = VerificationRemoteDataSource(
        api: BffVerificationApi(config: config),
      );
      authRepository = BffAuthRepository(
        config: config,
        localDataSource: authLocalDataSource,
        remoteDataSource: authRemoteDataSource,
      );
      verificationRepository = BffVerificationRepository(
        authRepository: authRepository,
        localDataSource: authLocalDataSource,
        remoteDataSource: verificationRemoteDataSource,
      );
    }

    // ApiClient subscribes to sessionChanges; the bloc's AuthStarted event
    // emits the restored session on that stream, so the client picks up
    // the bearer before the first /api/* call.
    final apiClient = ApiClient.create(
      config: config,
      authRepository: authRepository,
    );

    runApp(SmartApp(
      config: config,
      authRepository: authRepository,
      verificationRepository: verificationRepository,
      apiClient: apiClient,
    ));
  } catch (error, stack) {
    // audit-004 C-03: any failure before runApp(SmartApp) would otherwise
    // leave the user staring at a black screen. Mount BootFailureApp
    // instead — it shows the AppConfigException message verbatim
    // (deployment-misconfig diagnostics are dev-safe) and offers a Retry.
    ErrorReporter.instance.reportBootFailure(error, stack);
    runApp(BootFailureApp(
      error: error,
      stackTrace: stack,
      onRetry: _bootstrap,
    ));
  }
}

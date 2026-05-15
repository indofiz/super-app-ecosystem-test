import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/http/api_client.dart';
import 'core/storage/secure_store.dart';
import 'features/auth/data/bff_auth_repository.dart';
import 'features/auth/data/mock_auth_repository.dart';
import 'features/auth/domain/auth_repository.dart';
import 'features/verification/data/bff_verification_repository.dart';
import 'features/verification/data/mock_verification_repository.dart';
import 'features/verification/domain/verification_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');

  final config = AppConfig.fromEnv();
  final secureStore = SecureStore();

  // Composition root — the one place that picks mock vs BFF. AppConfig has
  // already validated that BFF fields are present when `useMockAuth=false`.
  final AuthRepository authRepository = config.useMockAuth
      ? MockAuthRepository(secureStore: secureStore)
      : BffAuthRepository(config: config, secureStore: secureStore);

  final VerificationRepository verificationRepository = config.useMockAuth
      ? MockVerificationRepository(
          authRepository: authRepository,
          secureStore: secureStore,
        )
      : BffVerificationRepository(
          config: config,
          authRepository: authRepository,
          secureStore: secureStore,
        );

  // ApiClient subscribes to sessionChanges; the bloc's AuthStarted event
  // emits the restored session on that stream, so the client picks up the
  // bearer before the first /api/* call.
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
}

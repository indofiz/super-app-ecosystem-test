import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/http/api_client.dart';
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');

  final config = AppConfig.fromEnv();
  final secureStore = SecureStore();

  // Composition root — the one place that picks mock vs BFF and wires the
  // data-source layer (audit-002 H-01). `AuthLocalDataSource` is shared
  // between the auth + verification features: both read the persisted
  // bearer from the same source of truth.
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

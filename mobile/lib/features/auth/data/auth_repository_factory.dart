import '../../../core/config/app_config.dart';
import '../../../core/storage/secure_store.dart';
import '../domain/auth_repository.dart';
import 'bff_auth_repository.dart';
import 'mock_auth_repository.dart';

/// Picks the auth repository based on `USE_MOCK_AUTH`. Missing or malformed
/// BFF config in non-mock mode is rejected at `AppConfig.fromEnv()` time;
/// by the time we reach here, both branches are safe to construct.
class AuthRepositoryFactory {
  static AuthRepository create({
    required AppConfig config,
    required SecureStore secureStore,
  }) {
    if (config.useMockAuth) {
      return MockAuthRepository(secureStore: secureStore);
    }
    return BffAuthRepository(config: config, secureStore: secureStore);
  }
}

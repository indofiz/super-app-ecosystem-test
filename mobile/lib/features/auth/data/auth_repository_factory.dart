import '../../../core/config/app_config.dart';
import '../../../core/storage/secure_store.dart';
import '../domain/auth_repository.dart';
import 'bff_auth_repository.dart';
import 'mock_auth_repository.dart';

class AuthRepositoryFactory {
  static AuthRepository create({
    required AppConfig config,
    required SecureStore secureStore,
  }) {
    if (config.useMockAuth || config.bffBaseUrl.isEmpty) {
      return MockAuthRepository(secureStore: secureStore);
    }
    return BffAuthRepository(config: config, secureStore: secureStore);
  }
}

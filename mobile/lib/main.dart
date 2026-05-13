import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/storage/secure_store.dart';
import 'features/auth/data/auth_repository_factory.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');

  final config = AppConfig.fromEnv();
  final secureStore = SecureStore();
  final authRepository = AuthRepositoryFactory.create(
    config: config,
    secureStore: secureStore,
  );

  runApp(SmartApp(
    config: config,
    authRepository: authRepository,
  ));
}

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'l10n/app_localizations.dart';
import 'core/config/app_config.dart';
import 'core/http/api_client.dart';
import 'core/router/app_router.dart';
import 'features/auth/domain/auth_repository.dart';
import 'features/auth/presentation/bloc/auth_bloc.dart';
import 'features/auth/presentation/bloc/auth_bloc_listenable.dart';
import 'features/sample/data/sample_api.dart';
import 'features/verification/domain/verification_repository.dart';

class SmartApp extends StatefulWidget {
  const SmartApp({
    super.key,
    required this.config,
    required this.authRepository,
    required this.verificationRepository,
    required this.apiClient,
  });

  final AppConfig config;
  final AuthRepository authRepository;
  final VerificationRepository verificationRepository;
  final ApiClient apiClient;

  @override
  State<SmartApp> createState() => _SmartAppState();
}

class _SmartAppState extends State<SmartApp> {
  late final AuthBloc _authBloc;
  late final AuthBlocListenable _authListenable;
  late final AppRouter _router;
  late final SampleApi _sampleApi;

  @override
  void initState() {
    super.initState();
    _authBloc = AuthBloc(authRepository: widget.authRepository)
      ..add(const AuthStarted());
    _authListenable = AuthBlocListenable(_authBloc);
    _router = AppRouter(status: _authListenable);
    _sampleApi = SampleApi(dio: widget.apiClient.dio);
  }

  @override
  void dispose() {
    // Order matters: tear down subscribers before disposing the repos so
    // they don't observe a closed sessionChanges stream.
    _authListenable.dispose();
    _authBloc.close();
    widget.apiClient.dispose();
    widget.verificationRepository.dispose();
    widget.authRepository.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<AppConfig>.value(value: widget.config),
        RepositoryProvider<AuthRepository>.value(value: widget.authRepository),
        RepositoryProvider<VerificationRepository>.value(
          value: widget.verificationRepository,
        ),
        RepositoryProvider<SampleApi>.value(value: _sampleApi),
      ],
      child: BlocProvider<AuthBloc>.value(
        value: _authBloc,
        child: MaterialApp.router(
          title: 'Smart App',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F4E8C)),
            useMaterial3: true,
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: _router.config,
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'core/config/app_config.dart';
import 'core/router/app_router.dart';
import 'features/auth/domain/auth_repository.dart';
import 'features/auth/presentation/bloc/auth_bloc.dart';

class SmartApp extends StatefulWidget {
  const SmartApp({
    super.key,
    required this.config,
    required this.authRepository,
  });

  final AppConfig config;
  final AuthRepository authRepository;

  @override
  State<SmartApp> createState() => _SmartAppState();
}

class _SmartAppState extends State<SmartApp> {
  late final AuthBloc _authBloc;
  late final AppRouter _router;

  @override
  void initState() {
    super.initState();
    _authBloc = AuthBloc(authRepository: widget.authRepository)
      ..add(const AuthStarted());
    _router = AppRouter(authBloc: _authBloc);
  }

  @override
  void dispose() {
    _authBloc.close();
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<AppConfig>.value(value: widget.config),
        RepositoryProvider<AuthRepository>.value(value: widget.authRepository),
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
          routerConfig: _router.config,
        ),
      ),
    );
  }
}

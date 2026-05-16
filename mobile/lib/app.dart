import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import 'l10n/app_localizations.dart';
import 'core/config/app_config.dart';
import 'core/http/api_client.dart';
import 'core/logging/error_reporter.dart';
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

    // audit-004 C-04: replace the default Flutter red/grey error box.
    // Errors thrown inside any descendant widget's build() are caught by
    // FlutterError.reportError and routed here. In debug we keep the
    // default red box so devs see the failure immediately; in release we
    // render a friendly localised tile with a reload affordance and
    // forward the details to ErrorReporter.
    ErrorWidget.builder = (FlutterErrorDetails details) {
      ErrorReporter.instance.reportFlutterError(details);
      if (kDebugMode) {
        return ErrorWidget(details.exception);
      }
      return _ReleaseErrorTile(router: _router.config);
    };

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
          // audit-003 L-01: keep the debug banner in non-release builds so
          // QA/help-desk screenshots visibly distinguish a debug build
          // (full logging, mock toggle reachable) from a real release.
          debugShowCheckedModeBanner: !kReleaseMode,
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

/// Release-build fallback for [ErrorWidget.builder]. Replaces the broken
/// subtree with a card the user can read and act on. Localised via
/// [AppLocalizations] — this runs inside a mounted [MaterialApp] so the
/// delegates are available.
class _ReleaseErrorTile extends StatelessWidget {
  const _ReleaseErrorTile({required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context) {
    // `Localizations.of` requires a Material/Widgets context. ErrorWidget
    // is rendered as a direct child of whatever was building when the
    // exception fired, so the inherited widget chain is intact.
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              color: theme.colorScheme.error,
              size: 32,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.errorWidgetMessage,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () {
                // Re-enter the current route so the broken subtree is
                // rebuilt from scratch. If the failure is deterministic
                // it will re-throw — but at least the user has the same
                // affordance any web page offers.
                final location =
                    router.routerDelegate.currentConfiguration.uri.toString();
                router.go(location);
              },
              icon: const Icon(Icons.refresh),
              label: Text(l10n.errorWidgetReload),
            ),
          ],
        ),
      ),
    );
  }
}

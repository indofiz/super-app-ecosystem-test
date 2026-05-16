import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:smart_app_test/features/auth/domain/auth_repository.dart';
import 'package:smart_app_test/features/auth/domain/auth_session.dart';
import 'package:smart_app_test/features/auth/presentation/bloc/auth_bloc.dart';

class _MockAuthRepository extends Mock implements AuthRepository {}

void main() {
  late _MockAuthRepository repo;
  late StreamController<AuthSession?> sessionController;

  AuthSession validSession() => AuthSession(
        accessToken: 'jwt',
        sessionId: 'sid-1',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        emailVerified: false,
        phoneNumberVerified: false,
      );

  AuthSession expiredSession() => AuthSession(
        accessToken: 'jwt-old',
        sessionId: 'sid-1',
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
        emailVerified: false,
        phoneNumberVerified: false,
      );

  setUp(() {
    repo = _MockAuthRepository();
    sessionController = StreamController<AuthSession?>.broadcast();
    when(() => repo.sessionChanges).thenAnswer((_) => sessionController.stream);
  });

  tearDown(() async {
    await sessionController.close();
  });

  group('AuthStarted', () {
    blocTest<AuthBloc, AuthState>(
      'emits unauthenticated when no session is stored',
      build: () {
        when(repo.restoreSession).thenAnswer((_) async => null);
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const AuthStarted()),
      expect: () => [const AuthState.unauthenticated()],
    );

    blocTest<AuthBloc, AuthState>(
      'emits authenticated directly for a fresh local session',
      // audit-002 H-05: restoreSession no longer emits on the stream.
      // The bloc emits `authenticated` from the handler itself.
      build: () {
        final s = validSession();
        when(repo.restoreSession).thenAnswer((_) async => s);
        // audit-003 C-05: cold start re-confirms identity via /auth/me in
        // the background after lifting the restored session.
        when(() => repo.confirmIdentity()).thenAnswer((_) async {});
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) async {
        bloc.add(const AuthStarted());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (bloc) {
        expect(bloc.state.status, AuthStatus.authenticated);
        expect(bloc.state.session, isNotNull);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'expired restored session triggers silent refresh '
      '→ authenticating, then authenticated via stream on success',
      // audit-002 H-05: an expired local session no longer means
      // unauthenticated. The bloc emits `authenticating` and calls
      // refresh(). The successful refresh emits on the stream;
      // _onSessionChanged lifts to authenticated.
      build: () {
        when(repo.restoreSession).thenAnswer((_) async => expiredSession());
        when(() => repo.refresh()).thenAnswer((_) async {
          final fresh = validSession();
          sessionController.add(fresh);
          return fresh;
        });
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) async {
        bloc.add(const AuthStarted());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (bloc) {
        expect(bloc.state.status, AuthStatus.authenticated);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'expired restored session, refresh fails → unauthenticated with code',
      build: () {
        when(repo.restoreSession).thenAnswer((_) async => expiredSession());
        when(() => repo.refresh()).thenThrow(
          AuthFailure(code: AuthErrorCode.sessionExpired),
        );
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const AuthStarted()),
      expect: () => [
        const AuthState.authenticating(),
        const AuthState.unauthenticated(
          errorCode: AuthErrorCode.sessionExpired,
        ),
      ],
    );
  });

  group('AuthLoginRequested', () {
    blocTest<AuthBloc, AuthState>(
      'emits authenticating then authenticated on success',
      build: () {
        when(repo.login).thenAnswer((_) async {
          final s = validSession();
          sessionController.add(s);
          return s;
        });
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) async {
        bloc.add(const AuthLoginRequested());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (bloc) {
        expect(bloc.state.status, AuthStatus.authenticated);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'emits authenticating then unauthenticated with code on AuthFailure',
      build: () {
        when(repo.login).thenThrow(
          AuthFailure(code: AuthErrorCode.loginPlatformError),
        );
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const AuthLoginRequested()),
      expect: () => [
        const AuthState.authenticating(),
        const AuthState.unauthenticated(
          errorCode: AuthErrorCode.loginPlatformError,
        ),
      ],
    );
  });

  group('AuthRefreshRequested', () {
    blocTest<AuthBloc, AuthState>(
      'emits authenticated with new session on success',
      build: () {
        when(() => repo.refresh()).thenAnswer((_) async {
          final s = validSession();
          sessionController.add(s);
          return s;
        });
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) async {
        bloc.add(const AuthRefreshRequested());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (bloc) {
        expect(bloc.state.status, AuthStatus.authenticated);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'emits unauthenticated with code when refresh fails',
      build: () {
        when(() => repo.refresh()).thenThrow(
          AuthFailure(code: AuthErrorCode.refreshFailed),
        );
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const AuthRefreshRequested()),
      expect: () => [
        const AuthState.unauthenticated(
          errorCode: AuthErrorCode.refreshFailed,
        ),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'refresh-401 path: stream null emission does not clobber the error code',
      // The real BFF refresh-401 path emits null on the stream AND throws.
      // The handler's explicit `unauthenticated(errorCode: ...)` must survive
      // the subsequent `_AuthSessionChanged(null)` event.
      build: () {
        when(() => repo.refresh()).thenAnswer((_) async {
          sessionController.add(null);
          throw AuthFailure(code: AuthErrorCode.sessionExpired);
        });
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) async {
        bloc.add(const AuthRefreshRequested());
        // Let the stream-emitted _AuthSessionChanged process too.
        await Future<void>.delayed(Duration.zero);
      },
      verify: (bloc) {
        expect(bloc.state.status, AuthStatus.unauthenticated);
        expect(bloc.state.errorCode, AuthErrorCode.sessionExpired);
      },
    );
  });

  group('AuthLogoutRequested', () {
    blocTest<AuthBloc, AuthState>(
      'emits unauthenticated after logout',
      // Logout emits null on the stream; the bloc reaches unauthenticated
      // via _onSessionChanged, not via an explicit handler emit.
      build: () {
        when(() => repo.logout()).thenAnswer((_) async {
          sessionController.add(null);
        });
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) async {
        bloc.add(const AuthLogoutRequested());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (bloc) {
        expect(bloc.state.status, AuthStatus.unauthenticated);
        expect(bloc.state.errorCode, isNull);
      },
    );
  });

  group('session stream', () {
    blocTest<AuthBloc, AuthState>(
      'emits authenticated when repo broadcasts a new session',
      build: () => AuthBloc(authRepository: repo),
      act: (_) async {
        sessionController.add(validSession());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (bloc) {
        expect(bloc.state.status, AuthStatus.authenticated);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'emits unauthenticated when repo broadcasts null from authenticated',
      build: () => AuthBloc(authRepository: repo),
      seed: () => AuthState.authenticated(validSession()),
      act: (_) async {
        sessionController.add(null);
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [const AuthState.unauthenticated()],
    );
  });
}

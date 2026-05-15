import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/logging/auth_log.dart';
import '../../domain/auth_error_code.dart';
import '../../domain/auth_repository.dart';
import '../../domain/auth_session.dart';
import '../../domain/auth_status.dart';

export '../../domain/auth_error_code.dart';
export '../../domain/auth_status.dart';

part 'auth_event.dart';
part 'auth_state.dart';

final _log = authLogger('bloc');

/// Source-of-truth rules (M-05):
///
///   • Bloc handlers emit ONLY transient + error states:
///       - `authenticating` (in-flight login)
///       - `unauthenticated(errorCode: ...)` (typed failures)
///       - `unauthenticated()` on app start when storage is empty
///   • The `authenticated` state is driven exclusively by
///     `authRepository.sessionChanges`. Whenever the repo emits a new
///     session — from login, refresh, restoreSession, replaceSession,
///     or any future out-of-band path — `_onSessionChanged` projects it
///     onto `state`.
///   • `_onSessionChanged(null)` will NOT clobber an error state set by
///     a handler. The refresh-401 path adds null on the stream AND
///     throws an `AuthFailure(sessionExpired)`; the handler emits the
///     typed error and the queued null becomes a no-op.
///
/// This collapses the dual-path race the audit flagged: handlers and
/// the stream-mirror no longer compete to set the success state.
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  AuthBloc({required this.authRepository}) : super(const AuthState.unknown()) {
    on<AuthStarted>(_onStarted);
    on<AuthLoginRequested>(_onLoginRequested);
    on<AuthLogoutRequested>(_onLogoutRequested);
    on<AuthRefreshRequested>(_onRefreshRequested);
    on<_AuthSessionChanged>(_onSessionChanged);

    _sub = authRepository.sessionChanges
        .listen((s) => add(_AuthSessionChanged(s)));
  }

  final AuthRepository authRepository;
  late final StreamSubscription<AuthSession?> _sub;

  Future<void> _onStarted(AuthStarted event, Emitter<AuthState> emit) async {
    // audit-002 H-05: restoreSession() no longer emits on the stream.
    // This handler classifies the restored session and either:
    //   - emits `unauthenticated` for null storage,
    //   - emits `authenticated` directly for a fresh local session,
    //   - emits `authenticating` and triggers a silent refresh for an
    //     expired one (the refresh path emits on the stream on success
    //     and emits null on `sessionExpired` failure).
    _log('onStarted');
    final session = await authRepository.restoreSession();
    if (session == null) {
      _log('onStarted → unauthenticated (no session)');
      emit(const AuthState.unauthenticated());
      return;
    }
    if (session.isExpired) {
      _log('onStarted → expired session, attempting silent refresh');
      emit(const AuthState.authenticating());
      try {
        await authRepository.refresh();
        _log('onStarted → refresh OK (state will be emitted by stream)');
      } on AuthFailure catch (e) {
        _log('onStarted → refresh failed ($e)');
        emit(AuthState.unauthenticated(errorCode: e.code));
      }
      return;
    }
    _log('onStarted → authenticated (fresh local session)');
    emit(AuthState.authenticated(session));
  }

  Future<void> _onLoginRequested(
      AuthLoginRequested event, Emitter<AuthState> emit) async {
    _log('onLoginRequested → authenticating');
    emit(const AuthState.authenticating());
    try {
      await authRepository.login();
      _log('onLoginRequested → success (state will be emitted by stream)');
      // No explicit emit here — login() pushed the new session onto
      // `sessionChanges` and `_onSessionChanged` will emit `authenticated`.
    } on AuthFailure catch (e) {
      _log('onLoginRequested → unauthenticated ($e, retryable=${e.retryable})');
      emit(AuthState.unauthenticated(errorCode: e.code));
    } catch (e) {
      _log('onLoginRequested → unauthenticated (unexpected: $e)');
      emit(const AuthState.unauthenticated(errorCode: AuthErrorCode.unknown));
    }
  }

  Future<void> _onLogoutRequested(
      AuthLogoutRequested event, Emitter<AuthState> emit) async {
    // logout() clears storage and emits null on `sessionChanges`.
    // `_onSessionChanged(null)` lifts the bloc into `unauthenticated()`.
    await authRepository.logout();
  }

  Future<void> _onRefreshRequested(
      AuthRefreshRequested event, Emitter<AuthState> emit) async {
    try {
      await authRepository.refresh();
      // Success — `_onSessionChanged` will emit `authenticated`.
    } on AuthFailure catch (e) {
      // No retry-after-refresh-failed: a dead refresh forces the user back
      // through SSO. The login screen will show this error.
      //
      // Note: on a 401 the repo also adds null to `sessionChanges` before
      // throwing. That queues a `_AuthSessionChanged(null)` after this
      // handler — the guard in `_onSessionChanged` preserves this error
      // state.
      emit(AuthState.unauthenticated(errorCode: e.code));
    }
  }

  void _onSessionChanged(_AuthSessionChanged event, Emitter<AuthState> emit) {
    final s = event.session;
    if (s == null || s.isExpired) {
      // null OR expired both mean "no usable session". The repo's
      // restoreSession emits even expired sessions on the stream; the
      // bloc treats them the same as null so an expired stream emit
      // can't accidentally lift the bloc into `authenticated`.
      //
      // Preserve an error state set by a handler — the refresh-401 path
      // adds null on the stream AND throws, and the handler's typed
      // error is the user-visible signal.
      if (state.status == AuthStatus.unauthenticated &&
          state.errorCode != null) {
        return;
      }
      // Don't churn from a clean unauthenticated state either.
      if (state.status == AuthStatus.unauthenticated) return;
      emit(const AuthState.unauthenticated());
    } else if (state.session != s) {
      emit(AuthState.authenticated(s));
    }
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    return super.close();
  }
}

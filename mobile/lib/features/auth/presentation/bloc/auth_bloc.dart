import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/logging/auth_log.dart';
import '../../domain/auth_repository.dart';
import '../../domain/auth_session.dart';

part 'auth_event.dart';
part 'auth_state.dart';

void _log(String msg) => authLog('bloc', msg);

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
    _log('onStarted');
    final session = await authRepository.restoreSession();
    if (session == null || session.isExpired) {
      _log('onStarted → unauthenticated (session=${session != null ? 'expired' : 'null'})');
      emit(const AuthState.unauthenticated());
    } else {
      _log('onStarted → authenticated');
      emit(AuthState.authenticated(session));
    }
  }

  Future<void> _onLoginRequested(
      AuthLoginRequested event, Emitter<AuthState> emit) async {
    _log('onLoginRequested → authenticating');
    emit(const AuthState.authenticating());
    try {
      final session = await authRepository.login();
      _log('onLoginRequested → authenticated');
      emit(AuthState.authenticated(session));
    } on AuthFailure catch (e) {
      _log('onLoginRequested → unauthenticated (AuthFailure: ${e.message}, retryable=${e.retryable})');
      emit(AuthState.unauthenticated(errorMessage: e.message));
    } catch (e) {
      _log('onLoginRequested → unauthenticated (unexpected: $e)');
      emit(AuthState.unauthenticated(errorMessage: 'Login failed: $e'));
    }
  }

  Future<void> _onLogoutRequested(
      AuthLogoutRequested event, Emitter<AuthState> emit) async {
    await authRepository.logout();
    emit(const AuthState.unauthenticated());
  }

  Future<void> _onRefreshRequested(
      AuthRefreshRequested event, Emitter<AuthState> emit) async {
    try {
      final session = await authRepository.refresh();
      emit(AuthState.authenticated(session));
    } on AuthFailure catch (e) {
      // No retry-after-refresh-failed: a dead refresh forces the user back
      // through SSO. The login screen will show this message.
      emit(AuthState.unauthenticated(errorMessage: e.message));
    }
  }

  void _onSessionChanged(_AuthSessionChanged event, Emitter<AuthState> emit) {
    final s = event.session;
    if (s == null) {
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

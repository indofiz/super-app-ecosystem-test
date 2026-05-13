part of 'auth_bloc.dart';

enum AuthStatus { unknown, unauthenticated, authenticating, authenticated }

class AuthState extends Equatable {
  const AuthState({
    required this.status,
    this.session,
    this.errorMessage,
  });

  const AuthState.unknown() : this(status: AuthStatus.unknown);
  const AuthState.unauthenticated({String? errorMessage})
      : this(status: AuthStatus.unauthenticated, errorMessage: errorMessage);
  const AuthState.authenticating() : this(status: AuthStatus.authenticating);
  const AuthState.authenticated(AuthSession session)
      : this(status: AuthStatus.authenticated, session: session);

  final AuthStatus status;
  final AuthSession? session;
  final String? errorMessage;

  @override
  List<Object?> get props => [status, session, errorMessage];
}

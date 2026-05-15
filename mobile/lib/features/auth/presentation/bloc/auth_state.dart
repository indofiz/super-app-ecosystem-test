part of 'auth_bloc.dart';

class AuthState extends Equatable {
  const AuthState({
    required this.status,
    this.session,
    this.errorCode,
  });

  const AuthState.unknown() : this(status: AuthStatus.unknown);
  const AuthState.unauthenticated({AuthErrorCode? errorCode})
      : this(status: AuthStatus.unauthenticated, errorCode: errorCode);
  const AuthState.authenticating() : this(status: AuthStatus.authenticating);
  const AuthState.authenticated(AuthSession session)
      : this(status: AuthStatus.authenticated, session: session);

  final AuthStatus status;
  final AuthSession? session;

  /// Typed error from the last auth action, or null if none.
  /// Presentation layer maps this to a localized string via
  /// `authErrorMessage(AppLocalizations, code)`.
  final AuthErrorCode? errorCode;

  @override
  List<Object?> get props => [status, session, errorCode];
}

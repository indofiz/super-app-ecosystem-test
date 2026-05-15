/// Lifecycle phases of authentication.
///
/// Lives in `domain/` (not in `presentation/bloc/`) so non-presentation
/// callers — notably the router — can depend on the enum without
/// importing flutter_bloc or the bloc itself.
enum AuthStatus {
  /// Initial state at app start, before [AuthRepository.restoreSession]
  /// has completed. The splash screen is shown.
  unknown,

  /// Either no session was found at start, or one was found but is
  /// expired / explicitly logged out / refresh-failed.
  unauthenticated,

  /// A login (or refresh) is in flight.
  authenticating,

  /// A non-expired session is available; `AuthBloc.state.session` is non-null.
  authenticated,
}

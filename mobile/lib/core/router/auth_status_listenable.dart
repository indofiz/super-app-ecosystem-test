import 'package:flutter/foundation.dart';

import '../../features/auth/domain/auth_status.dart';

/// Read-only auth status with change notifications.
///
/// `AppRouter` depends on THIS, not on `AuthBloc`. Concrete adapters live
/// next to whichever state manager owns auth (currently `AuthBloc`, but
/// could be Riverpod / a pure Stream in a fork without touching `core/`).
///
/// Implementations must call [notifyListeners] when [status] changes so
/// go_router's `refreshListenable` re-evaluates the redirect.
abstract class AuthStatusListenable extends ChangeNotifier {
  AuthStatus get status;
}

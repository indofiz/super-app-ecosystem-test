import 'dart:async';

import '../../../../core/router/auth_status_listenable.dart';
import 'auth_bloc.dart';

/// Adapts an [AuthBloc] to the framework-neutral [AuthStatusListenable]
/// the router consumes. Keeps `core/router/` free of `flutter_bloc`.
class AuthBlocListenable extends AuthStatusListenable {
  AuthBlocListenable(AuthBloc bloc) : _status = bloc.state.status {
    _sub = bloc.stream.listen((s) {
      if (s.status != _status) {
        _status = s.status;
        notifyListeners();
      }
    });
  }

  AuthStatus _status;
  late final StreamSubscription<AuthState> _sub;

  @override
  AuthStatus get status => _status;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

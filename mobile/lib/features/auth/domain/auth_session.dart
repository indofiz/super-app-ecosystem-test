import 'package:equatable/equatable.dart';

class AuthSession extends Equatable {
  const AuthSession({
    required this.accessToken,
    required this.sessionId,
    required this.expiresAt,
    this.idToken,
  });

  final String accessToken;
  final String sessionId;
  final DateTime expiresAt;
  final String? idToken;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  AuthSession copyWith({
    String? accessToken,
    String? sessionId,
    DateTime? expiresAt,
    String? idToken,
  }) {
    return AuthSession(
      accessToken: accessToken ?? this.accessToken,
      sessionId: sessionId ?? this.sessionId,
      expiresAt: expiresAt ?? this.expiresAt,
      idToken: idToken ?? this.idToken,
    );
  }

  @override
  List<Object?> get props => [accessToken, sessionId, expiresAt, idToken];
}

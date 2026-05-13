import 'package:equatable/equatable.dart';

class AuthSession extends Equatable {
  const AuthSession({
    required this.accessToken,
    required this.sessionId,
    required this.expiresAt,
  });

  final String accessToken;
  final String sessionId;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  AuthSession copyWith({
    String? accessToken,
    String? sessionId,
    DateTime? expiresAt,
  }) {
    return AuthSession(
      accessToken: accessToken ?? this.accessToken,
      sessionId: sessionId ?? this.sessionId,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }

  @override
  List<Object?> get props => [accessToken, sessionId, expiresAt];
}

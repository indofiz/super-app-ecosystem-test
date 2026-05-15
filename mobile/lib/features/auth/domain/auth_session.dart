import 'package:equatable/equatable.dart';

import '../../../core/storage/stored_session.dart';
import 'jwt_claims.dart';

class AuthSession extends Equatable {
  const AuthSession({
    required this.accessToken,
    required this.sessionId,
    required this.expiresAt,
    required this.emailVerified,
    required this.phoneNumberVerified,
    this.email,
    this.phoneNumber,
  });

  /// Construct a session from a freshly-issued internal JWT. The
  /// verification flags + identity fields are derived from the JWT
  /// payload — same source the BFF mints from, same source Kong reads.
  factory AuthSession.fromToken({
    required String accessToken,
    required String sessionId,
    required DateTime expiresAt,
  }) {
    final claims = JwtClaims.fromToken(accessToken);
    return AuthSession(
      accessToken: accessToken,
      sessionId: sessionId,
      expiresAt: expiresAt,
      email: claims.email,
      emailVerified: claims.emailVerified,
      phoneNumber: claims.phoneNumber,
      phoneNumberVerified: claims.phoneNumberVerified,
    );
  }

  /// Decode a raw [StoredSession] from `SecureStore.readSession()`. Same
  /// JWT decode as [fromToken], just plumbed via the storage value type.
  factory AuthSession.fromStored(StoredSession s) => AuthSession.fromToken(
        accessToken: s.accessToken,
        sessionId: s.sessionId,
        expiresAt: s.expiresAt,
      );

  /// Project this session back into its raw three-field storage shape.
  /// Drops the JWT-decoded fields — they're derived from `accessToken`.
  StoredSession toStored() => StoredSession(
        accessToken: accessToken,
        sessionId: sessionId,
        expiresAt: expiresAt,
      );

  final String accessToken;
  final String sessionId;
  final DateTime expiresAt;
  final String? email;
  final bool emailVerified;
  final String? phoneNumber;
  final bool phoneNumberVerified;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
  bool get fullyVerified => emailVerified && phoneNumberVerified;

  AuthSession copyWith({
    String? accessToken,
    String? sessionId,
    DateTime? expiresAt,
    String? email,
    bool? emailVerified,
    String? phoneNumber,
    bool? phoneNumberVerified,
  }) {
    return AuthSession(
      accessToken: accessToken ?? this.accessToken,
      sessionId: sessionId ?? this.sessionId,
      expiresAt: expiresAt ?? this.expiresAt,
      email: email ?? this.email,
      emailVerified: emailVerified ?? this.emailVerified,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      phoneNumberVerified: phoneNumberVerified ?? this.phoneNumberVerified,
    );
  }

  @override
  List<Object?> get props => [
        accessToken,
        sessionId,
        expiresAt,
        email,
        emailVerified,
        phoneNumber,
        phoneNumberVerified,
      ];
}

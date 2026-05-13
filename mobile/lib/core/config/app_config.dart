import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  const AppConfig({
    required this.bffBaseUrl,
    required this.oauthClientId,
    required this.oauthRedirectUri,
    required this.oauthScopes,
    required this.useMockAuth,
    required this.allowInsecureConnections,
  });

  final String bffBaseUrl;
  final String oauthClientId;
  final String oauthRedirectUri;
  final List<String> oauthScopes;
  final bool useMockAuth;
  final bool allowInsecureConnections;

  factory AppConfig.fromEnv() {
    bool readBool(String key, {required bool fallback}) {
      final raw = dotenv.env[key]?.toLowerCase().trim();
      if (raw == null || raw.isEmpty) return fallback;
      return raw == 'true' || raw == '1' || raw == 'yes';
    }

    return AppConfig(
      bffBaseUrl: dotenv.env['BFF_BASE_URL']?.trim() ?? '',
      oauthClientId: dotenv.env['OAUTH_CLIENT_ID']?.trim() ?? '',
      oauthRedirectUri: dotenv.env['OAUTH_REDIRECT_URI']?.trim() ?? '',
      oauthScopes: (dotenv.env['OAUTH_SCOPES'] ?? 'openid profile email')
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .toList(),
      useMockAuth: readBool('USE_MOCK_AUTH', fallback: true),
      allowInsecureConnections:
          readBool('ALLOW_INSECURE_CONNECTIONS', fallback: false),
    );
  }

  // BFF endpoints. The app NEVER constructs Keycloak URLs directly —
  // this is the security boundary (see memory: feedback_security_bff_only).
  String get authorizationEndpoint => '$bffBaseUrl/auth/authorize';
  String get tokenEndpoint => '$bffBaseUrl/auth/token';
  String get refreshEndpoint => '$bffBaseUrl/auth/refresh';
  String get logoutEndpoint => '$bffBaseUrl/auth/logout';
  String get meEndpoint => '$bffBaseUrl/auth/me';
}

import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Thrown at startup when `.env` is missing values the BFF flow needs.
/// Surfacing this loudly is intentional: a silently misconfigured app
/// would otherwise drop back to the mock repo and look like it works
/// against the real backend.
class AppConfigException implements Exception {
  AppConfigException(this.message);
  final String message;
  @override
  String toString() => 'AppConfigException: $message';
}

/// Application configuration sourced from `.env` (bundled as a Flutter
/// asset) at startup.
///
/// SECURITY — `.env` USAGE RULES:
/// 1. `.env` is bundled inside the APK/IPA. ANYONE who unpacks the
///    binary can read every value. Treat it as **public data**.
/// 2. Allowed contents: build-time defaults for non-secret routing
///    (`BFF_BASE_URL`, `OAUTH_CLIENT_ID`, `OAUTH_REDIRECT_URI`,
///    `USE_MOCK_AUTH`, `ALLOW_INSECURE_CONNECTIONS`).
/// 3. DO NOT add secrets — no API keys, no client secrets, no signing
///    keys, no tokens. Examples of values that must NEVER appear here:
///    `FONNTE_API_KEY`, `KEYCLOAK_CLIENT_SECRET`, anything ending in
///    `*_SECRET` or `*_KEY`. Those belong on the BFF, which mobile
///    talks to via the bearer-mediated session.
/// 4. For per-environment overrides at build time, prefer
///    `--dart-define=X=Y` flags read with `String.fromEnvironment` —
///    those are baked into the binary at compile time and don't ship
///    as a readable asset.
/// 5. Releasing with `USE_MOCK_AUTH=true` would silently auth every
///    user as `mock-user-####`. Ship `false` in production builds.
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

    final useMockAuth = readBool('USE_MOCK_AUTH', fallback: true);
    final bffBaseUrl = dotenv.env['BFF_BASE_URL']?.trim() ?? '';
    final oauthClientId = dotenv.env['OAUTH_CLIENT_ID']?.trim() ?? '';
    final oauthRedirectUri = dotenv.env['OAUTH_REDIRECT_URI']?.trim() ?? '';
    final allowInsecure =
        readBool('ALLOW_INSECURE_CONNECTIONS', fallback: false);

    if (!useMockAuth) {
      if (bffBaseUrl.isEmpty) {
        throw AppConfigException(
          'BFF_BASE_URL is required when USE_MOCK_AUTH=false. '
          'Set it in .env to the nginx-fronted BFF (e.g. http://10.0.2.2:8080).',
        );
      }
      final uri = Uri.tryParse(bffBaseUrl);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        throw AppConfigException(
          'BFF_BASE_URL="$bffBaseUrl" is not a valid absolute URL.',
        );
      }
      if (uri.scheme == 'http' && !allowInsecure) {
        throw AppConfigException(
          'BFF_BASE_URL uses http:// but ALLOW_INSECURE_CONNECTIONS is false. '
          'Use https:// in production, or set ALLOW_INSECURE_CONNECTIONS=true for local dev.',
        );
      }
      if (oauthClientId.isEmpty) {
        throw AppConfigException('OAUTH_CLIENT_ID is required.');
      }
      if (oauthRedirectUri.isEmpty) {
        throw AppConfigException('OAUTH_REDIRECT_URI is required.');
      }
    }

    return AppConfig(
      bffBaseUrl: bffBaseUrl,
      oauthClientId: oauthClientId,
      oauthRedirectUri: oauthRedirectUri,
      oauthScopes: (dotenv.env['OAUTH_SCOPES'] ?? 'openid profile email')
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .toList(),
      useMockAuth: useMockAuth,
      allowInsecureConnections: allowInsecure,
    );
  }

  // BFF endpoints. The app NEVER constructs Keycloak URLs directly —
  // this is the security boundary.
  String get authorizationEndpoint => '$bffBaseUrl/auth/authorize';
  String get tokenEndpoint => '$bffBaseUrl/auth/token';
  String get refreshEndpoint => '$bffBaseUrl/auth/refresh';
  String get logoutEndpoint => '$bffBaseUrl/auth/logout';
  String get meEndpoint => '$bffBaseUrl/auth/me';
}

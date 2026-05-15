import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_appauth/flutter_appauth.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/auth_timings.dart';
import '../../../core/logging/auth_log.dart';
import '../../../core/network/bff_error.dart';
import '../../../core/storage/secure_store.dart';
import '../domain/auth_error_code.dart';
import '../domain/auth_repository.dart';
import '../domain/auth_session.dart';
import 'bff_auth_api.dart';

final _log = authLogger('repo');

/// Real BFF-mediated auth repository.
///
/// Uses flutter_appauth pointed at BFF endpoints (NOT Keycloak directly).
/// The BFF performs the OAuth/PKCE handshake with Keycloak, then mints a
/// short-lived HS256 INTERNAL JWT that mobile carries as its Bearer.
/// Keycloak's access_token never reaches this repository.
///
/// The OAuth response from /auth/token is:
///   `{ access_token: internal-jwt, token_type, expires_in, scope, session_id }`
/// `session_id` arrives via flutter_appauth's `tokenAdditionalParameters`.
class BffAuthRepository implements AuthRepository {
  BffAuthRepository({
    required this.config,
    required this.secureStore,
    FlutterAppAuth? appAuth,
    BffAuthApi? api,
  })  : _appAuth = appAuth ?? const FlutterAppAuth(),
        _ownsApi = api == null,
        _api = api ?? BffAuthApi(config: config);

  final AppConfig config;
  final SecureStore secureStore;
  final FlutterAppAuth _appAuth;
  final BffAuthApi _api;
  // True when this repo constructed its own [BffAuthApi] and therefore owns
  // its lifecycle. When injected (tests), the caller disposes it.
  final bool _ownsApi;

  final _controller = StreamController<AuthSession?>.broadcast();

  @override
  Stream<AuthSession?> get sessionChanges => _controller.stream;

  @override
  Future<AuthSession?> restoreSession() async {
    _log('restoreSession: reading secure storage');
    final stored = await secureStore.readSession();
    if (stored == null) {
      _log('restoreSession: no stored session');
      return null;
    }
    _log(
        'restoreSession: found session, sid=${stored.sessionId.substring(0, 6)}…, expiresAt=${stored.expiresAt.toIso8601String()}');
    final session = AuthSession.fromStored(stored);
    _controller.add(session);
    return session;
  }

  @override
  Future<AuthSession> login() async {
    _log('login: START');
    _log('login: clientId=${config.oauthClientId}');
    _log('login: redirectUri=${config.oauthRedirectUri}');
    _log('login: authEndpoint=${config.authorizationEndpoint}');
    _log('login: tokenEndpoint=${config.tokenEndpoint}');
    _log('login: scopes=${config.oauthScopes.join(' ')}');
    _log('login: allowInsecure=${config.allowInsecureConnections}');
    final stopwatch = Stopwatch()..start();
    try {
      _log('login: calling authorizeAndExchangeCode (timeout=${kOauthLoginTimeout.inSeconds}s)');
      final result = await _appAuth
          .authorizeAndExchangeCode(
            AuthorizationTokenRequest(
              config.oauthClientId,
              config.oauthRedirectUri,
              serviceConfiguration: AuthorizationServiceConfiguration(
                authorizationEndpoint: config.authorizationEndpoint,
                tokenEndpoint: config.tokenEndpoint,
              ),
              scopes: config.oauthScopes,
              allowInsecureConnections: config.allowInsecureConnections,
              promptValues: const ['login'],
            ),
          )
          .timeout(kOauthLoginTimeout);
      _log('login: AppAuth returned in ${stopwatch.elapsedMilliseconds}ms');
      _log('login: accessToken? ${result.accessToken != null} (len=${result.accessToken?.length ?? 0})');
      _log('login: idToken? ${result.idToken != null}');
      _log('login: tokenType=${result.tokenType}');
      _log('login: expiresAt=${result.accessTokenExpirationDateTime?.toIso8601String()}');
      _log('login: additionalParams=${result.tokenAdditionalParameters?.keys.toList()}');

      final accessToken = result.accessToken;
      final expiresAt = result.accessTokenExpirationDateTime;
      // BFF returns session_id alongside the access token via additionalParameters.
      final sessionId =
          result.tokenAdditionalParameters?['session_id']?.toString();
      _log('login: parsed sessionId=${sessionId == null ? 'NULL' : '${sessionId.substring(0, sessionId.length.clamp(0, 6))}…'}');

      if (accessToken == null || expiresAt == null || sessionId == null) {
        _log('login: FAIL — missing required fields (accessToken=${accessToken != null}, expiresAt=${expiresAt != null}, sessionId=${sessionId != null})');
        throw AuthFailure(
          code: AuthErrorCode.loginMissingFields,
          diagnostic:
              'access_token=${accessToken != null} expires_in=${expiresAt != null} session_id=${sessionId != null}',
        );
      }

      // Note: result.idToken is null with the new BFF — we store null here and
      // fetch profile via /auth/me when needed. `fromToken` decodes the JWT
      // payload and seeds emailVerified / phoneNumberVerified from the
      // BFF-signed claims — avoids a /auth/me round-trip after every refresh.
      final session = AuthSession.fromToken(
        accessToken: accessToken,
        sessionId: sessionId,
        expiresAt: expiresAt,
      );

      _log('login: writing session to secure storage');
      await secureStore.writeSession(session.toStored());
      _log('login: SUCCESS in ${stopwatch.elapsedMilliseconds}ms');
      _controller.add(session);
      return session;
    } on TimeoutException catch (e) {
      _log('login: TIMEOUT after ${stopwatch.elapsedMilliseconds}ms — AppAuth never returned (likely Android killed the task while Custom Tab was open)');
      throw AuthFailure(
        code: AuthErrorCode.loginTimedOut,
        cause: e,
        retryable: true,
      );
    } on FlutterAppAuthUserCancelledException catch (e) {
      _log('login: CANCELLED after ${stopwatch.elapsedMilliseconds}ms — code=${e.code} msg=${e.message}');
      // "User cancelled" can also fire when AppAuth fails to discover a
      // browser, when the Custom Tabs intent fails to launch, or when a
      // launchMode mismatch loses the redirect callback. The diagnostic
      // captures both so logs can tell which.
      throw AuthFailure(
        code: AuthErrorCode.loginCancelled,
        diagnostic: 'code=${e.code} msg=${e.message}',
        cause: e,
        retryable: true,
      );
    } on FlutterAppAuthPlatformException catch (e) {
      _log('login: PLATFORM ERROR after ${stopwatch.elapsedMilliseconds}ms — code=${e.code} msg=${e.message}');
      throw AuthFailure(
        code: AuthErrorCode.loginPlatformError,
        diagnostic: 'code=${e.code} msg=${e.message}',
        cause: e,
      );
    } catch (e, st) {
      _log('login: UNEXPECTED ERROR after ${stopwatch.elapsedMilliseconds}ms — $e');
      _log('login: stack=$st');
      throw AuthFailure(
        code: AuthErrorCode.unknown,
        diagnostic: '$e',
        cause: e,
      );
    }
  }

  @override
  Future<AuthSession> refresh() async {
    final stored = await secureStore.readSession();
    if (stored == null) {
      throw AuthFailure(code: AuthErrorCode.notAuthenticated);
    }
    // BFF requires the bearer (§2.1). Even an expired access_token works
    // — the BFF accepts up to 24h past expiry on /refresh.
    try {
      final res = await _api.refresh(
        sessionId: stored.sessionId,
        bearer: stored.accessToken,
      );
      final session = AuthSession.fromToken(
        accessToken: res.accessToken,
        sessionId: res.sessionId,
        expiresAt: DateTime.now().add(Duration(seconds: res.expiresIn)),
      );
      await secureStore.writeSession(session.toStored());
      _controller.add(session);
      return session;
    } on DioException catch (e) {
      // The BFF says the server-side session is gone (Redis wiped, BFF
      // restarted, or session explicitly invalidated). Local credentials
      // are now useless — wipe them and emit null so the bloc reaches
      // unauthenticated. Otherwise the user lingers in a half-authed
      // state where every subsequent call also 401s.
      final status = e.response?.statusCode;
      final body = e.response?.data;
      final isInvalidSession = status == 401 ||
          (body is Map && body['error'] == 'invalid_session');
      if (isInvalidSession) {
        _log('refresh: session gone server-side → clearing local state');
        await secureStore.clear();
        _controller.add(null);
        throw AuthFailure(
          code: AuthErrorCode.sessionExpired,
          cause: e,
        );
      }
      throw _mapDio(e, fallback: AuthErrorCode.refreshFailed);
    }
  }

  @override
  Future<void> logout() async {
    final stored = await secureStore.readSession();
    if (stored != null) {
      try {
        await _api.logout(
          sessionId: stored.sessionId,
          bearer: stored.accessToken,
        );
      } catch (_) {
        // Best-effort: still wipe local state if BFF is unreachable.
      }
    }
    await secureStore.clear();
    _controller.add(null);
  }

  @override
  Future<UserProfile> getProfile() async {
    final stored = await secureStore.readSession();
    if (stored == null) {
      throw AuthFailure(code: AuthErrorCode.notAuthenticated);
    }
    final body = await _api.getMe(stored.accessToken);
    final roles = (body['roles'] as List?)?.cast<String>() ?? const [];
    final expiresAt = body['expiresAt'] is String
        ? DateTime.tryParse(body['expiresAt'] as String)
        : null;
    return UserProfile(
      sub: (body['sub'] as String?) ?? '',
      username: body['username'] as String?,
      email: body['email'] as String?,
      emailVerified: body['emailVerified'] == true,
      phoneNumber: body['phoneNumber'] as String?,
      phoneNumberVerified: body['phoneNumberVerified'] == true,
      roles: roles,
      expiresAt: expiresAt,
    );
  }

  @override
  Future<void> replaceSession(AuthSession session) async {
    await secureStore.writeSession(session.toStored());
    _controller.add(session);
  }

  @override
  Future<void> dispose() async {
    if (_ownsApi) await _api.dispose();
    await _controller.close();
  }

  /// Map a Dio error into a typed [AuthFailure]. [fallback] is the code
  /// assigned when this isn't a network-level timeout. The BFF's
  /// `error_description` is captured as a diagnostic for logs — it is
  /// never shown to the user.
  AuthFailure _mapDio(DioException e, {required AuthErrorCode fallback}) {
    final info = describeBffError(e);
    return AuthFailure(
      code: info.isTimeout ? AuthErrorCode.network : fallback,
      diagnostic: info.errorDescription,
      cause: e,
      retryable: info.isTimeout,
    );
  }
}

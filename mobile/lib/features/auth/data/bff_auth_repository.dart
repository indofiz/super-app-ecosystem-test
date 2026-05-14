import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_appauth/flutter_appauth.dart';

import '../../../core/config/app_config.dart';
import '../../../core/logging/auth_log.dart';
import '../../../core/storage/secure_store.dart';
import '../domain/auth_repository.dart';
import '../domain/auth_session.dart';
import 'bff_auth_api.dart';

void _log(String msg) => authLog('repo', msg);

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
        _api = api ?? BffAuthApi(config: config);

  final AppConfig config;
  final SecureStore secureStore;
  final FlutterAppAuth _appAuth;
  final BffAuthApi _api;

  final _controller = StreamController<AuthSession?>.broadcast();

  @override
  Stream<AuthSession?> get sessionChanges => _controller.stream;

  AuthSession _toSession({
    required String accessToken,
    required String sessionId,
    required DateTime expiresAt,
  }) =>
      // `fromToken` decodes the JWT payload and seeds emailVerified /
      // phoneNumberVerified from the BFF-signed claims. Avoids a /auth/me
      // round-trip after every refresh just to read the flags.
      AuthSession.fromToken(
        accessToken: accessToken,
        sessionId: sessionId,
        expiresAt: expiresAt,
      );

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
    final session = _toSession(
      accessToken: stored.accessToken,
      sessionId: stored.sessionId,
      expiresAt: stored.expiresAt,
    );
    _controller.add(session);
    return session;
  }

  /// Hard cap on the AppAuth round-trip. If Android kills the app's task while
  /// the Custom Tab is open, AppAuth's `AuthorizationManagementActivity` loses
  /// its in-memory state and logs `No stored state - unable to handle response`,
  /// then `finish()`s without ever completing the Future. Without this timeout
  /// the bloc would sit in `authenticating` forever.
  static const _loginTimeout = Duration(minutes: 3);

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
      _log('login: calling authorizeAndExchangeCode (timeout=${_loginTimeout.inSeconds}s)');
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
          .timeout(_loginTimeout);
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
          'BFF response missing required fields (access_token / expires_in / session_id).',
        );
      }

      // Note: result.idToken is null with the new BFF — we store null here and
      // fetch profile via /auth/me when needed.
      final session = _toSession(
        accessToken: accessToken,
        sessionId: sessionId,
        expiresAt: expiresAt,
      );

      _log('login: writing session to secure storage');
      await secureStore.writeSession(
        accessToken: session.accessToken,
        sessionId: session.sessionId,
        expiresAt: session.expiresAt,
      );
      _log('login: SUCCESS in ${stopwatch.elapsedMilliseconds}ms');
      _controller.add(session);
      return session;
    } on TimeoutException catch (e) {
      _log('login: TIMEOUT after ${stopwatch.elapsedMilliseconds}ms — AppAuth never returned (likely Android killed the task while Custom Tab was open)');
      throw AuthFailure(
        'Login timed out — please try again.',
        cause: e,
        retryable: true,
      );
    } on FlutterAppAuthUserCancelledException catch (e) {
      _log('login: CANCELLED after ${stopwatch.elapsedMilliseconds}ms — code=${e.code} msg=${e.message}');
      // "User cancelled" can also fire when AppAuth fails to discover a
      // browser, when the Custom Tabs intent fails to launch, or when a
      // launchMode mismatch loses the redirect callback. Surface the code
      // and message so we can tell which.
      throw AuthFailure(
        'Login cancelled (code=${e.code} msg=${e.message})',
        cause: e,
        retryable: true,
      );
    } on FlutterAppAuthPlatformException catch (e) {
      _log('login: PLATFORM ERROR after ${stopwatch.elapsedMilliseconds}ms — code=${e.code} msg=${e.message}');
      throw AuthFailure(
        'Login failed (code=${e.code} msg=${e.message})',
        cause: e,
      );
    } catch (e, st) {
      _log('login: UNEXPECTED ERROR after ${stopwatch.elapsedMilliseconds}ms — $e');
      _log('login: stack=$st');
      throw AuthFailure('Login failed: $e', cause: e);
    }
  }

  @override
  Future<AuthSession> refresh() async {
    final stored = await secureStore.readSession();
    if (stored == null) {
      throw AuthFailure('No session to refresh.');
    }
    // BFF requires the bearer (§2.1). Even an expired access_token works
    // — the BFF accepts up to 24h past expiry on /refresh.
    final res = await _api.refresh(
      sessionId: stored.sessionId,
      bearer: stored.accessToken,
    );
    final session = _toSession(
      accessToken: res.accessToken,
      sessionId: res.sessionId,
      expiresAt: DateTime.now().add(Duration(seconds: res.expiresIn)),
    );
    await secureStore.writeSession(
      accessToken: session.accessToken,
      sessionId: session.sessionId,
      expiresAt: session.expiresAt,
    );
    _controller.add(session);
    return session;
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
      throw AuthFailure('Not authenticated');
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
  Future<Duration> sendEmailOtp() async {
    final stored = await secureStore.readSession();
    if (stored == null) throw AuthFailure('Not authenticated');
    try {
      final res = await _api.sendEmailOtp(stored.accessToken);
      _log('sendEmailOtp: delivery=${res.delivery} '
          'alreadyVerified=${res.alreadyVerified}');
      return Duration(seconds: res.expiresIn);
    } on DioException catch (e) {
      throw _mapDio(e, fallback: 'Gagal mengirim OTP email.');
    }
  }

  @override
  Future<AuthSession> verifyEmailOtp(String code) async {
    final stored = await secureStore.readSession();
    if (stored == null) throw AuthFailure('Not authenticated');
    try {
      final res = await _api.verifyEmailOtp(stored.accessToken, code);
      final session = _toSession(
        accessToken: res.accessToken,
        sessionId: res.sessionId,
        expiresAt: DateTime.now().add(Duration(seconds: res.expiresIn)),
      );
      await secureStore.writeSession(
        accessToken: session.accessToken,
        sessionId: session.sessionId,
        expiresAt: session.expiresAt,
      );
      _controller.add(session);
      _log('verifyEmailOtp: SUCCESS');
      return session;
    } on DioException catch (e) {
      throw _mapVerifyDio(e);
    }
  }

  @override
  Future<Duration> sendPhoneOtp(String phone) async {
    final stored = await secureStore.readSession();
    if (stored == null) throw AuthFailure('Not authenticated');
    try {
      final res = await _api.sendPhoneOtp(stored.accessToken, phone);
      _log('sendPhoneOtp: delivery=${res.delivery} '
          'alreadyVerified=${res.alreadyVerified}');
      return Duration(seconds: res.expiresIn);
    } on DioException catch (e) {
      throw _mapDio(e, fallback: 'Gagal mengirim OTP WhatsApp.');
    }
  }

  @override
  Future<AuthSession> verifyPhoneOtp(String phone, String code) async {
    final stored = await secureStore.readSession();
    if (stored == null) throw AuthFailure('Not authenticated');
    try {
      final res = await _api.verifyPhoneOtp(stored.accessToken, phone, code);
      final session = _toSession(
        accessToken: res.accessToken,
        sessionId: res.sessionId,
        expiresAt: DateTime.now().add(Duration(seconds: res.expiresIn)),
      );
      await secureStore.writeSession(
        accessToken: session.accessToken,
        sessionId: session.sessionId,
        expiresAt: session.expiresAt,
      );
      _controller.add(session);
      _log('verifyPhoneOtp: SUCCESS');
      return session;
    } on DioException catch (e) {
      throw _mapVerifyDio(e);
    }
  }

  /// Map a Dio error from a verify-OTP call into the typed failures the
  /// bloc expects. The BFF's error vocabulary:
  ///   - 410 otp_expired / otp_exhausted → OtpExpiredFailure
  ///   - 422 otp_invalid (with attempts_left) → OtpInvalidFailure
  ///   - everything else → generic AuthFailure
  AuthFailure _mapVerifyDio(DioException e) {
    final status = e.response?.statusCode;
    final body = e.response?.data;
    if (status == 410) {
      return OtpExpiredFailure(cause: e);
    }
    if (status == 422 && body is Map) {
      // BFF puts `attempts_left` inside the HttpError detail. The error
      // middleware projects it as `{error, error_description, detail}`.
      final detail = body['detail'];
      final attemptsLeft = detail is Map && detail['attempts_left'] is num
          ? (detail['attempts_left'] as num).toInt()
          : 0;
      return OtpInvalidFailure(attemptsLeft: attemptsLeft, cause: e);
    }
    return _mapDio(e, fallback: 'Verifikasi gagal.');
  }

  AuthFailure _mapDio(DioException e, {required String fallback}) {
    final body = e.response?.data;
    String? desc;
    if (body is Map && body['error_description'] is String) {
      desc = body['error_description'] as String;
    }
    final retryable =
        e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.sendTimeout;
    return AuthFailure(desc ?? fallback, cause: e, retryable: retryable);
  }
}

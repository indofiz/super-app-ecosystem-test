import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_appauth/flutter_appauth.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/auth_timings.dart';
import '../../../core/logging/auth_log.dart';
import '../../../core/network/bff_error.dart';
import '../../../core/network/bff_parse.dart';
import '../../../core/network/cancelled_exception.dart';
import '../domain/auth_error_code.dart';
import '../domain/auth_repository.dart';
import '../domain/auth_session.dart';
import 'datasources/auth_local_datasource.dart';
import 'datasources/auth_remote_datasource.dart';

final _log = authLogger('repo');

/// Real BFF-mediated auth repository.
///
/// Orchestrates exactly two collaborators:
///   - [AuthLocalDataSource] — persisted-session shape, hides
///     `SecureStore` / `StoredSession`.
///   - [AuthRemoteDataSource] — BFF `/auth/*` calls, hides `BffAuthApi` /
///     Dio.
///
/// Plus [FlutterAppAuth] for the OAuth deeplink round-trip on [login].
/// Everything else is orchestration (audit-002 H-01).
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
    required AuthLocalDataSource localDataSource,
    required AuthRemoteDataSource remoteDataSource,
    FlutterAppAuth? appAuth,
  })  : _local = localDataSource,
        _remote = remoteDataSource,
        _appAuth = appAuth ?? const FlutterAppAuth();

  final AppConfig config;
  final AuthLocalDataSource _local;
  final AuthRemoteDataSource _remote;
  final FlutterAppAuth _appAuth;

  final _controller = StreamController<AuthSession?>.broadcast();

  /// audit-004 H-02: in-flight dedup at the repository layer. The bloc's
  /// `AuthRefreshRequested` (e.g. the dev Refresh icon) and the
  /// `_RefreshInterceptor`'s 401-driven retry can both invoke `refresh()`
  /// concurrently. The BFF rotates the Keycloak refresh_token on each
  /// call (§2.1), so two parallel rotations invalidate each other and
  /// the loser's bearer 401s on the next request. Sharing one Completer
  /// across concurrent callers means at most one rotation per "wave".
  ///
  /// The interceptor's own `_refreshOnce` Completer is kept as
  /// defence-in-depth — when both layers have a dedup, the interceptor's
  /// is effectively a no-op because the repo Future is already shared.
  Completer<AuthSession>? _refreshing;

  @override
  Stream<AuthSession?> get sessionChanges => _controller.stream;

  @override
  Future<AuthSession?> restoreSession() async {
    // audit-002 H-05: NO stream emit here. The bloc decides whether the
    // restored session is fresh enough to lift into `authenticated`
    // directly, or whether to trigger a silent refresh first. Emitting
    // would let `ApiClient`'s token holder cache an expired bearer
    // before the bloc could classify it.
    _log('restoreSession: reading local store');
    final session = await _local.read();
    if (session == null) {
      _log('restoreSession: no stored session');
      return null;
    }
    _log(
        'restoreSession: found session, sid=${session.sessionId.substring(0, 6)}…, expiresAt=${session.expiresAt.toIso8601String()}');
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

      final session = AuthSession.fromToken(
        accessToken: accessToken,
        sessionId: sessionId,
        expiresAt: expiresAt,
      );

      _log('login: writing session to local store');
      await _local.write(session);
      // Replace JWT-decoded flags with BFF-confirmed values from /auth/me.
      final enriched = await _enrichFromProfile(session);
      if (enriched != session) await _local.write(enriched);
      _log('login: SUCCESS in ${stopwatch.elapsedMilliseconds}ms');
      _controller.add(enriched);
      return enriched;
    } on TimeoutException catch (e) {
      _log('login: TIMEOUT after ${stopwatch.elapsedMilliseconds}ms — AppAuth never returned (likely Android killed the task while Custom Tab was open)');
      throw AuthFailure(
        code: AuthErrorCode.loginTimedOut,
        cause: e,
        retryable: true,
      );
    } on FlutterAppAuthUserCancelledException catch (e) {
      _log('login: CANCELLED after ${stopwatch.elapsedMilliseconds}ms — code=${e.code} msg=${e.message}');
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
  Future<AuthSession> refresh({CancelToken? cancel}) {
    // audit-004 H-02: share one in-flight refresh across concurrent
    // callers. A second caller arriving while a refresh is already in
    // flight awaits the same Future instead of triggering a second
    // rotation. Note: a join-er's `cancel` token does not interrupt the
    // shared refresh — matches the pre-existing interceptor dedup
    // behaviour, since one tab's cancellation should not abort another's
    // session restoration.
    final inflight = _refreshing;
    if (inflight != null) {
      _log('refresh: joining in-flight refresh');
      return inflight.future;
    }
    final c = Completer<AuthSession>();
    _refreshing = c;
    _doRefresh(cancel: cancel).then((session) {
      _refreshing = null;
      c.complete(session);
    }, onError: (Object e, StackTrace st) {
      _refreshing = null;
      c.completeError(e, st);
    });
    return c.future;
  }

  Future<AuthSession> _doRefresh({CancelToken? cancel}) async {
    final stored = await _local.read();
    if (stored == null) {
      throw AuthFailure(code: AuthErrorCode.notAuthenticated);
    }
    // BFF requires the bearer (§2.1). Even an expired access_token works
    // — the BFF accepts up to 24h past expiry on /refresh.
    try {
      final res = await _remote.refresh(
        sessionId: stored.sessionId,
        bearer: stored.accessToken,
        cancel: cancel,
      );
      // C-03 scenario 3 guard: a concurrent `logout()` may have cleared
      // storage while we were awaiting the refresh response. Writing the
      // fresh session now would resurrect a session the user just signed
      // out of. Drop the result silently — the bloc already saw null on
      // the stream from logout().
      final current = await _local.read();
      if (current == null) {
        _log('refresh: aborting write — local store cleared mid-flight (logout race)');
        throw AuthFailure(code: AuthErrorCode.notAuthenticated);
      }
      // /auth/refresh may omit `session_id` when the rotation does not
      // change it — fall back to the stored ID in that case.
      final session = AuthSession.fromToken(
        accessToken: res.accessToken,
        sessionId: res.sessionId ?? stored.sessionId,
        expiresAt: DateTime.now().add(Duration(seconds: res.expiresIn)),
      );
      await _local.write(session);
      // Replace JWT-decoded flags with BFF-confirmed values from /auth/me.
      final enriched = await _enrichFromProfile(session);
      if (enriched != session) await _local.write(enriched);
      _controller.add(enriched);
      return enriched;
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
        await _local.clear();
        _controller.add(null);
        throw AuthFailure(
          code: AuthErrorCode.sessionExpired,
          cause: e,
        );
      }
      throw _mapDio(e, fallback: AuthErrorCode.refreshFailed);
    } on CancelledException {
      // Caller-initiated cancellation propagates verbatim; the local
      // session stays intact because we never wrote anything.
      rethrow;
    } on BffParseFailure catch (e) {
      _log('refresh: BFF contract violation → $e');
      throw AuthFailure(
        code: AuthErrorCode.refreshFailed,
        diagnostic: '$e',
        cause: e,
      );
    } on TypeError catch (e, st) {
      // Defence in depth: a future call site that bypasses the parse
      // helpers would otherwise propagate a raw TypeError past the data
      // layer. Translate it identically (audit-002 C-01).
      _log('refresh: unexpected TypeError → $e\n$st');
      throw AuthFailure(
        code: AuthErrorCode.refreshFailed,
        diagnostic: 'TypeError: $e',
        cause: e,
      );
    }
  }

  @override
  Future<void> logout({CancelToken? cancel}) async {
    // audit-002 H-06: run the BFF logout and the local clear in PARALLEL.
    // The local clear used to wait for a 15s receiveTimeout if the BFF
    // was unreachable; during that window the app was in a half-logged-
    // out state where every page still saw a valid session in storage.
    // Now the local clear races the BFF call — whichever resolves first
    // doesn't block the other.
    //
    // The remote call is best-effort and never re-throws: a failure to
    // notify the BFF leaves a server-side zombie session (Redis entry +
    // Keycloak refresh_token), which is logged but not surfaced to the
    // user. A future pass should queue failed logouts for retry on next
    // launch (TODO: pending-logouts retry queue).
    final stored = await _local.read();
    final remoteCall = stored == null
        ? Future<void>.value()
        : _logoutRemoteBestEffort(stored, cancel: cancel);
    await Future.wait<void>([remoteCall, _local.clear()]);
    _controller.add(null);
  }

  /// Best-effort BFF logout — never re-throws. Logs every failure mode
  /// distinctly so the on-call engineer can tell a network blip from a
  /// genuine server reject:
  ///   - cancellation → caller-initiated; local clear still proceeds.
  ///   - timeouts / connectionError → expected on offline logout.
  ///   - 401 → server already considers the session dead. No zombie.
  ///   - other 4xx/5xx with body → likely zombie session; warning-level.
  Future<void> _logoutRemoteBestEffort(
    AuthSession session, {
    CancelToken? cancel,
  }) async {
    try {
      await _remote.logout(
        sessionId: session.sessionId,
        bearer: session.accessToken,
        cancel: cancel,
      );
      _log('logout: BFF acknowledged');
    } on CancelledException {
      _log('logout: BFF call cancelled by caller — local clear proceeds');
    } on DioException catch (e) {
      final info = describeBffError(e);
      if (info.isTimeout || e.type == DioExceptionType.connectionError) {
        _log('logout: BFF unreachable (${e.type.name}) '
            '— local clear proceeds');
      } else if (e.response?.statusCode == 401) {
        _log('logout: BFF returned 401 '
            '— session already invalid server-side');
      } else {
        _log('logout: BFF rejected logout status=${info.statusCode} '
            'desc=${info.errorDescription} '
            '— local clear proceeds, server-side session may persist');
      }
    } catch (e) {
      _log('logout: BFF logout failed unexpectedly ($e) '
          '— local clear proceeds');
    }
  }

  @override
  Future<UserProfile> getProfile({CancelToken? cancel}) async {
    final stored = await _local.read();
    if (stored == null) {
      throw AuthFailure(code: AuthErrorCode.notAuthenticated);
    }
    try {
      final dto =
          await _remote.getMe(bearer: stored.accessToken, cancel: cancel);
      return UserProfile(
        sub: dto.sub,
        username: dto.username,
        email: dto.email,
        emailVerified: dto.emailVerified,
        phoneNumber: dto.phoneNumber,
        phoneNumberVerified: dto.phoneNumberVerified,
        roles: dto.roles,
        expiresAt: dto.expiresAt,
      );
    } on DioException catch (e) {
      throw _mapDio(e, fallback: AuthErrorCode.unknown);
    } on BffParseFailure catch (e) {
      _log('getProfile: BFF contract violation → $e');
      throw AuthFailure(
        code: AuthErrorCode.unknown,
        diagnostic: '$e',
        cause: e,
      );
    } on TypeError catch (e, st) {
      _log('getProfile: unexpected TypeError → $e\n$st');
      throw AuthFailure(
        code: AuthErrorCode.unknown,
        diagnostic: 'TypeError: $e',
        cause: e,
      );
    }
  }

  @override
  Future<void> replaceSession(AuthSession session) async {
    await _local.write(session);
    _controller.add(session);
  }

  /// Best-effort enrichment: calls `/auth/me` to replace JWT-decoded identity
  /// flags with BFF-confirmed values. If the call fails for any reason the
  /// original session is returned unchanged — JWT-decoded flags act as a
  /// degraded fallback rather than causing a hard login failure.
  Future<AuthSession> _enrichFromProfile(AuthSession session) async {
    try {
      final dto = await _remote.getMe(bearer: session.accessToken);
      final enriched = session.copyWith(
        email: dto.email,
        emailVerified: dto.emailVerified,
        phoneNumber: dto.phoneNumber,
        phoneNumberVerified: dto.phoneNumberVerified,
      );
      return enriched;
    } catch (e) {
      _log('_enrichFromProfile: /auth/me failed ($e) — using JWT-decoded flags');
      return session;
    }
  }

  @override
  Future<void> dispose() async {
    await _remote.dispose();
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

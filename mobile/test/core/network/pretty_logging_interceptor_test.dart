import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/core/config/app_config.dart';
import 'package:smart_app_test/core/network/pretty_logging_interceptor.dart';

AppConfig _config({required bool verbose}) => AppConfig(
      bffBaseUrl: 'https://bff.example',
      oauthClientId: 'super-app-eco',
      oauthRedirectUri: 'app:/cb',
      oauthScopes: const ['openid'],
      useMockAuth: false,
      allowInsecureConnections: false,
      httpVerboseLog: verbose,
    );

/// Captures the request the interceptor chain forwards to the wire, and
/// returns a canned JSON response so `onResponse` also fires.
class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? seen;
  String body = '{"access_token":"server-secret-xyz","ok":true}';

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen = options;
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }
}

void main() {
  group('prettyHttpLoggingInterceptor gate', () {
    test('returns null when httpVerboseLog is false', () {
      expect(prettyHttpLoggingInterceptor(_config(verbose: false)), isNull);
    });

    test('returns an interceptor when verbose (debug test runtime)', () {
      // `flutter test` runs in debug, so kDebugMode is true here.
      expect(
        prettyHttpLoggingInterceptor(_config(verbose: true)),
        isA<Interceptor>(),
      );
    });
  });

  group('verbatim logging + pass-through', () {
    late List<String> captured;
    late Dio dio;
    late _CapturingAdapter adapter;

    setUp(() {
      captured = [];
      adapter = _CapturingAdapter();
      dio = Dio(BaseOptions(baseUrl: 'https://bff.example'))
        ..httpClientAdapter = adapter
        ..interceptors.add(
          prettyHttpLoggingInterceptor(
            _config(verbose: true),
            debugSink: (o) => captured.add(o.toString()),
          )!,
        );
    });

    test('logs secrets verbatim and forwards the real request', () async {
      await dio.post<dynamic>(
        '/auth/phone/verify-otp',
        data: {'code': '123456', 'phone': '+628123456789'},
        options: Options(headers: {'Authorization': 'Bearer real-token-abc'}),
      );

      final log = captured.join('\n');

      // No redaction: every value is shown in full for debugging.
      expect(log, isNot(contains('«redacted»')));
      expect(log, contains('real-token-abc'));
      expect(log, contains('123456'));
      expect(log, contains('628123456789'));
      // Response body token is shown too.
      expect(log, contains('server-secret-xyz'));

      // Pass-through invariant: the live request the adapter received is
      // byte-for-byte the original — logging never touched the wire.
      final sent = adapter.seen!;
      expect(sent.headers['Authorization'], 'Bearer real-token-abc');
      expect((sent.data as Map)['code'], '123456');
      expect((sent.data as Map)['phone'], '+628123456789');
    });

    test('shows values, flags and timestamps verbatim', () async {
      adapter.body = '{'
          '"phoneNumber":"+628123456789",'
          '"phoneNumberVerified":true,'
          '"phoneVerifiedAt":"2026-05-16T00:00:00Z",'
          '"errorCode":"NONE",'
          '"accessToken":"tok-abc",'
          '"tokenType":"Bearer"'
          '}';
      await dio.get<dynamic>('/auth/me');
      final log = captured.join('\n');

      // PII / token values shown in full.
      expect(log, contains('628123456789'));
      expect(log, contains('tok-abc'));
      // Diagnostic flags/timestamps also present.
      expect(log, contains('phoneNumberVerified'));
      expect(log, contains('true'));
      expect(log, contains('phoneVerifiedAt'));
      expect(log, contains('2026-05-16T00:00:00Z'));
      expect(log, contains('errorCode'));
      expect(log, contains('"NONE"'));
      expect(log, contains('Bearer'));
    });

    test('renders request/response boxes', () async {
      await dio.post<dynamic>('/auth/phone/verify-otp',
          data: {'code': '999'});
      final log = captured.join('\n');
      expect(log, contains('Request'));
      expect(log, contains('Response'));
    });
  });
}

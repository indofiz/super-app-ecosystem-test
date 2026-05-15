import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:smart_app_test/core/storage/secure_store.dart';
import 'package:smart_app_test/core/storage/stored_session.dart';
import 'package:smart_app_test/features/auth/data/datasources/auth_local_datasource.dart';
import 'package:smart_app_test/features/auth/domain/auth_session.dart';

class _MockSecureStore extends Mock implements SecureStore {}

class _FakeStoredSession extends Fake implements StoredSession {}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeStoredSession());
  });

  late _MockSecureStore store;
  late AuthLocalDataSource local;

  setUp(() {
    store = _MockSecureStore();
    local = AuthLocalDataSource(secureStore: store);
  });

  group('read()', () {
    test('returns null when storage is empty', () async {
      when(store.readSession).thenAnswer((_) async => null);

      expect(await local.read(), isNull);
    });

    test('decodes a stored session into AuthSession via fromStored', () async {
      final expiresAt = DateTime.utc(2030, 1, 1);
      when(store.readSession).thenAnswer((_) async => StoredSession(
            // `garbage` is not a valid JWT — AuthSession.fromStored
            // falls back to the supplied expiresAt for that case, so
            // this exercises the fallback path explicitly.
            accessToken: 'garbage',
            sessionId: 'sid-1',
            expiresAt: expiresAt,
          ));

      final s = await local.read();
      expect(s, isA<AuthSession>());
      expect(s!.accessToken, 'garbage');
      expect(s.sessionId, 'sid-1');
      expect(s.expiresAt, expiresAt);
    });
  });

  group('write()', () {
    test('projects AuthSession down to the storage shape', () async {
      when(() => store.writeSession(any())).thenAnswer((_) async {});

      final session = AuthSession(
        accessToken: 'tok',
        sessionId: 'sid',
        expiresAt: DateTime.utc(2030),
        emailVerified: true,
        phoneNumberVerified: false,
      );

      await local.write(session);

      final captured = verify(() => store.writeSession(captureAny()))
          .captured
          .single as StoredSession;
      expect(captured.accessToken, 'tok');
      expect(captured.sessionId, 'sid');
      expect(captured.expiresAt, DateTime.utc(2030));
    });
  });

  group('clear()', () {
    test('delegates to SecureStore.clear', () async {
      when(store.clear).thenAnswer((_) async {});

      await local.clear();

      verify(store.clear).called(1);
    });
  });
}

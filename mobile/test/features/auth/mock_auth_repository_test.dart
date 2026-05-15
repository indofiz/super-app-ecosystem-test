import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/core/storage/secure_store.dart';
import 'package:smart_app_test/features/auth/data/mock_auth_repository.dart';

void main() {
  group('MockAuthRepository.dispose', () {
    test('closes the sessionChanges stream', () async {
      // We don't need a working storage backend — `dispose()` doesn't touch
      // it. The cast to `SecureStore` is purely structural.
      final repo = MockAuthRepository(secureStore: SecureStore());

      // Subscribe so a `done` event has somewhere to land.
      bool gotDone = false;
      final sub = repo.sessionChanges.listen(
        (_) {},
        onDone: () => gotDone = true,
      );

      await repo.dispose();
      // Give the stream a microtask to deliver the `done` event.
      await Future<void>.delayed(Duration.zero);

      expect(gotDone, isTrue,
          reason: 'dispose() should close the controller, propagating done');

      await sub.cancel();
    });
  });
}

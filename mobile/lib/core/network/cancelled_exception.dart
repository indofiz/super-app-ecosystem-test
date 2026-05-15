import 'package:dio/dio.dart';

/// Domain marker that an in-flight request was cancelled (audit-002 H-02).
///
/// The data layer catches `DioException(type: cancel)` and rethrows this
/// instead, so the presentation layer doesn't have to know about Dio.
/// Blocs catch this explicitly and skip emission — typically the
/// surrounding scope (the bloc itself or the widget) is being disposed,
/// so emitting after the await would race state-machine semantics.
///
/// Carries no payload — the *fact* of cancellation is the entire signal.
class CancelledException implements Exception {
  const CancelledException();

  @override
  String toString() => 'CancelledException';
}

/// Run [body] and translate any `DioException(type: cancel)` it throws
/// into a domain [CancelledException]. Every other exception (including
/// non-cancel DioExceptions) propagates verbatim.
///
/// Lives next to [CancelledException] so the wire-detail-to-domain
/// translation is in one place. Data-layer methods that pass a
/// `cancelToken` through to Dio should wrap their body in this helper —
/// repositories then catch `on CancelledException` instead of probing
/// `DioExceptionType.cancel` themselves.
Future<T> withCancelTranslation<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on DioException catch (e) {
    if (e.type == DioExceptionType.cancel) {
      throw const CancelledException();
    }
    rethrow;
  }
}

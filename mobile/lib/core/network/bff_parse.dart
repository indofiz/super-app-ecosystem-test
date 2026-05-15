import 'package:dio/dio.dart';

/// Thrown when a BFF response body violates its documented contract:
/// missing required field, wrong JSON type, or an empty body where one
/// is required. Lives at the data-source layer (`BffAuthApi`, `SampleApi`)
/// — repositories catch and translate to their feature-typed failures.
///
/// Carries enough context to debug in logs ([field], [reason]) without
/// leaking to UI copy: presentation must map by code, not by message
/// (same rule as `AuthFailure.diagnostic`).
class BffParseFailure implements Exception {
  BffParseFailure(this.field, this.reason, {this.cause});

  /// The JSON key (or `<body>` for whole-body failures) that failed.
  final String field;

  /// One of `missing` / `wrong-type:<Expected>` / `empty-body` /
  /// `not-an-object`.
  final String reason;

  final Object? cause;

  @override
  String toString() => 'BffParseFailure(field=$field, $reason)';
}

/// Unwrap a `Response<Map>` into a non-empty body, or throw
/// [BffParseFailure]. Callers use this instead of `res.data ?? const {}`
/// — the latter silently returns an empty map and lets every downstream
/// field-default kick in (audit-002 L-02).
Map<String, dynamic> requireBody(
  Response<Map<String, dynamic>> res,
  String endpoint,
) {
  final data = res.data;
  if (data == null) {
    throw BffParseFailure('<body>', 'empty-body');
  }
  if (data.isEmpty) {
    throw BffParseFailure('<body>', 'empty-body');
  }
  return data;
}

String requireString(Map<dynamic, dynamic> body, String key) {
  final v = body[key];
  if (v == null) throw BffParseFailure(key, 'missing');
  if (v is! String) throw BffParseFailure(key, 'wrong-type:String');
  return v;
}

String? optionalString(Map<dynamic, dynamic> body, String key) {
  final v = body[key];
  if (v == null) return null;
  if (v is! String) throw BffParseFailure(key, 'wrong-type:String');
  return v;
}

/// Required integer. Accepts JSON numbers (`int`/`double` → truncated)
/// AND numeric strings (`"3600"`) — some BFF middleware stringifies
/// numeric values when running behind certain proxies, and we'd rather
/// tolerate that than ship a `TypeError` to the user.
int requireInt(Map<dynamic, dynamic> body, String key) {
  final parsed = _tryReadInt(body[key]);
  if (parsed == null) {
    if (body[key] == null) throw BffParseFailure(key, 'missing');
    throw BffParseFailure(key, 'wrong-type:int');
  }
  return parsed;
}

int? optionalInt(Map<dynamic, dynamic> body, String key) {
  final v = body[key];
  if (v == null) return null;
  final parsed = _tryReadInt(v);
  if (parsed == null) throw BffParseFailure(key, 'wrong-type:int');
  return parsed;
}

bool optionalBool(
  Map<dynamic, dynamic> body,
  String key, {
  bool fallback = false,
}) {
  final v = body[key];
  if (v == null) return fallback;
  if (v is bool) return v;
  throw BffParseFailure(key, 'wrong-type:bool');
}

int? _tryReadInt(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

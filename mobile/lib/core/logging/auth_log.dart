import 'package:flutter/foundation.dart';

/// Debug-only logger used by the auth stack. Centralised so prefixes stay
/// consistent and so a future swap to a real logging package is one edit.
///
/// SECURITY: never pass raw tokens, session_ids, or any bearer to this. The
/// auth files truncate before calling — keep it that way.
void authLog(String tag, String msg) {
  if (!kDebugMode) return;
  // ignore: avoid_print
  print('[AUTH/$tag] $msg');
}

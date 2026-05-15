import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/app_config.dart';

/// Fallback UI shown when `main()`'s prelude (dotenv load, AppConfig parse,
/// dependency wiring) throws before `runApp(SmartApp)` can mount.
///
/// l10n is intentionally **English only** — the AppLocalizations delegate
/// is not loaded at this point, and boot failures are a dev/ops surface
/// (deployment misconfiguration, missing `.env`, malformed `BFF_BASE_URL`)
/// not an end-user-facing flow.
class BootFailureApp extends StatefulWidget {
  const BootFailureApp({
    super.key,
    required this.error,
    this.stackTrace,
    required this.onRetry,
  });

  final Object error;
  final StackTrace? stackTrace;
  final Future<void> Function() onRetry;

  @override
  State<BootFailureApp> createState() => _BootFailureAppState();
}

class _BootFailureAppState extends State<BootFailureApp> {
  bool _retrying = false;

  Future<void> _handleRetry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F4E8C)),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.error_outline, size: 64, color: Colors.redAccent),
                    const SizedBox(height: 16),
                    Text(
                      'Failed to start',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _description(widget.error),
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    if (kDebugMode) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${widget.error}\n\n${widget.stackTrace ?? ""}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _retrying ? null : _handleRetry,
                      icon: _retrying
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: Text(_retrying ? 'Retrying…' : 'Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _description(Object error) {
    // AppConfigException carries a developer-friendly message that is safe
    // to surface (missing env keys, malformed URL, http without insecure
    // override). Anything else collapses to a generic line.
    if (error is AppConfigException) return error.message;
    return 'An unexpected error occurred while starting the app.';
  }
}

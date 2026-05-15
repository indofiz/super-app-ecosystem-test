import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/logging/error_reporter.dart';
import '../../core/network/api_failure.dart';
import '../../core/network/cancelled_exception.dart';
import '../auth/domain/auth_repository.dart';
import '../auth/domain/auth_session.dart';
import '../auth/domain/jwt_claims.dart';
import '../auth/presentation/bloc/auth_bloc.dart';
import '../sample/data/sample_api.dart';

/// Diagnostic widgets used during BFF/Kong integration development.
///
/// Every export here MUST be wrapped in `if (kDebugMode)` at the call site
/// in production-facing code so the tree-shaker can drop it from release
/// bundles. Nothing in this file should be referenced from a path the
/// citizen build can reach unguarded.
///
/// Contents:
///   - [DevRefreshAction]  : AppBar icon that fires AuthRefreshRequested.
///   - [DevDashboard]      : Panel that previews the JWT, decodes claims,
///                           and exercises `/auth/me` + `/api/profile`.

class DevRefreshAction extends StatelessWidget {
  const DevRefreshAction({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Refresh token (dev)',
      icon: const Icon(Icons.refresh),
      onPressed: () =>
          context.read<AuthBloc>().add(const AuthRefreshRequested()),
    );
  }
}

class DevDashboard extends StatefulWidget {
  const DevDashboard({super.key, required this.session});

  final AuthSession session;

  @override
  State<DevDashboard> createState() => _DevDashboardState();
}

class _DevDashboardState extends State<DevDashboard> {
  String? _meResult;
  String? _apiResult;
  // audit-004 M-07: per-button error state. The original
  // `HomeScreen._error` site has been refactored away (HomeScreen no
  // longer owns an error field), but the same single-bucket pattern was
  // surviving here on the team's smoke-test surface. Back-to-back
  // failures used to overwrite each other; now each button keeps its own
  // result and only its own catch arm sets it.
  String? _meError;
  String? _apiError;
  bool _busy = false;

  /// Cancels in-flight `/auth/me` + `/api/profile` calls on widget
  /// dispose (audit-002 H-02 scenario 2). Without this, a slow upstream
  /// could complete after the dashboard is gone and `setState` on an
  /// unmounted widget.
  final CancelToken _cancel = CancelToken();

  @override
  void dispose() {
    if (!_cancel.isCancelled) _cancel.cancel('DevDashboard.dispose');
    super.dispose();
  }

  Future<void> _run(
    void Function(String?) setError,
    Future<void> Function() task,
  ) async {
    setState(() {
      _busy = true;
      setError(null);
    });
    try {
      await task();
    } on CancelledException {
      // Widget disposed while a request was in flight — silently drop.
      return;
    } on ApiFailure catch (f) {
      if (!mounted) return;
      // Dev-only label: presentation code (when /api/* features ship to
      // citizens) will resolve `f.code` via AppLocalizations. Showing
      // the diagnostic here is fine — this widget is gated behind
      // `kDebugMode` at every call site.
      setState(() => setError('ApiFailure(${f.code.name})'
          '${f.diagnostic != null ? ' — ${f.diagnostic}' : ''}'));
    } catch (e, st) {
      // audit-004 H-01: don't interpolate `$e` into UI strings. With H-04
      // in place every realistic failure surfaces as a typed arm above —
      // this generic catch is defence-in-depth. Route the raw object
      // through the C-01 sink so the failure is still recorded.
      ErrorReporter.instance.reportError(e, st, context: 'devDashboard');
      if (!mounted) return;
      setState(() => setError('Unexpected: ${e.runtimeType}'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fetchMe() => _run((e) => _meError = e, () async {
        final repo = context.read<AuthRepository>();
        final profile = await repo.getProfile(cancel: _cancel);
        if (!mounted) return;
        setState(() {
          _meResult = const JsonEncoder.withIndent('  ').convert({
            'sub': profile.sub,
            'username': profile.username,
            'email': profile.email,
            'roles': profile.roles,
            'expiresAt': profile.expiresAt?.toIso8601String(),
          });
        });
      });

  Future<void> _fetchApiProfile() => _run((e) => _apiError = e, () async {
        final api = context.read<SampleApi>();
        final dto = await api.getProfile(cancel: _cancel);
        if (!mounted) return;
        setState(() {
          // `dto.raw` is the unmodified upstream body — kept so this
          // dev-only dashboard can hand-inspect the response shape while
          // real consumers migrate to typed fields on the DTO.
          _apiResult = const JsonEncoder.withIndent('  ').convert(dto.raw);
        });
      });

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final claims = JwtClaims.fromToken(session.accessToken).raw;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _row('session_id', session.sessionId),
        _row('expires_at', session.expiresAt.toIso8601String()),
        _row(
          'access_token (preview)',
          '${session.accessToken.substring(0, session.accessToken.length.clamp(0, 24))}…',
        ),
        const Divider(height: 32),
        Text(
          'Decoded internal JWT',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        SelectableText(const JsonEncoder.withIndent('  ').convert(claims)),
        const Divider(height: 32),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _fetchMe,
              icon: const Icon(Icons.person_outline),
              label: const Text('GET /auth/me  (BFF)'),
            ),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _fetchApiProfile,
              icon: const Icon(Icons.cloud_outlined),
              label: const Text('GET /api/profile  (Kong → service)'),
            ),
          ],
        ),
        if (_busy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
        if (_meError != null) ...[
          const SizedBox(height: 16),
          Text(
            '/auth/me: ${_meError!}',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (_apiError != null) ...[
          const SizedBox(height: 8),
          Text(
            '/api/profile: ${_apiError!}',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (_meResult != null) ...[
          const Divider(height: 32),
          Text(
            '/auth/me response',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          SelectableText(_meResult!),
        ],
        if (_apiResult != null) ...[
          const Divider(height: 32),
          Text(
            '/api/profile response',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          SelectableText(_apiResult!),
        ],
      ],
    );
  }

  static Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 140,
              child: Text(
                k,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Expanded(child: SelectableText(v)),
          ],
        ),
      );
}

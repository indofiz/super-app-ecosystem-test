import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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
  String? _error;
  bool _busy = false;

  Future<void> _run(Future<void> Function() task) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await task();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fetchMe() => _run(() async {
        final repo = context.read<AuthRepository>();
        final profile = await repo.getProfile();
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

  Future<void> _fetchApiProfile() => _run(() async {
        final api = context.read<SampleApi>();
        final body = await api.getProfile();
        setState(() {
          _apiResult = const JsonEncoder.withIndent('  ').convert(body);
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
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(
            _error!,
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

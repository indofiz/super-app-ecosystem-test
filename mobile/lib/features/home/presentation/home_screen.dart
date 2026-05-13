import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/config/app_config.dart';
import '../../auth/domain/auth_repository.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../sample/data/sample_api.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
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
        final session = context.read<AuthBloc>().state.session;
        if (session == null) throw Exception('No session');
        final api = SampleApi(config: context.read<AppConfig>());
        final body = await api.getProfile(session.accessToken);
        setState(() {
          _apiResult = const JsonEncoder.withIndent('  ').convert(body);
        });
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          IconButton(
            tooltip: 'Refresh token',
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                context.read<AuthBloc>().add(const AuthRefreshRequested()),
          ),
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                context.read<AuthBloc>().add(const AuthLogoutRequested()),
          ),
        ],
      ),
      body: BlocBuilder<AuthBloc, AuthState>(
        builder: (context, state) {
          final session = state.session;
          if (session == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final claims = _decodeClaims(session.accessToken);
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
        },
      ),
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

  static Map<String, dynamic> _decodeClaims(String jwt) {
    final parts = jwt.split('.');
    if (parts.length < 2) return const {};
    try {
      final padded = parts[1].padRight(parts[1].length + (4 - parts[1].length % 4) % 4, '=');
      final decoded = utf8.decode(base64Url.decode(padded));
      final map = jsonDecode(decoded);
      return map is Map<String, dynamic> ? map : {};
    } catch (_) {
      return {};
    }
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../auth/presentation/bloc/auth_bloc.dart';

/// Hub screen — shows current verification status for both channels and
/// lets the user enter either flow. Reads the verified flags directly
/// from `AuthBloc`'s session (the JWT-decoded source of truth), so the
/// status here updates the instant a verify call returns a new session.
class VerificationScreen extends StatelessWidget {
  const VerificationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verifikasi Akun')),
      body: BlocBuilder<AuthBloc, AuthState>(
        builder: (context, state) {
          final session = state.session;
          if (session == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Verifikasi email dan nomor WhatsApp Anda untuk membuka '
                'semua fitur layanan kota.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              _ChannelCard(
                icon: Icons.email_outlined,
                title: 'Email',
                subtitle: session.email ?? '—',
                verified: session.emailVerified,
                onVerifyTap: () => context.push('/verify/email'),
              ),
              const SizedBox(height: 12),
              _ChannelCard(
                icon: Icons.chat_outlined,
                title: 'WhatsApp',
                subtitle: session.phoneNumber ?? 'Belum terdaftar',
                verified: session.phoneNumberVerified,
                onVerifyTap: () => context.push('/verify/phone'),
              ),
              if (session.fullyVerified) ...[
                const SizedBox(height: 32),
                Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.verified_outlined,
                        size: 48,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Semua kontak Anda sudah terverifikasi.',
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ChannelCard extends StatelessWidget {
  const _ChannelCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.verified,
    required this.onVerifyTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool verified;
  final VoidCallback onVerifyTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 32, color: theme.colorScheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodyMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  if (verified)
                    Row(
                      children: [
                        Icon(
                          Icons.check_circle,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Terverifikasi',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    )
                  else
                    Text(
                      'Belum diverifikasi',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
            if (!verified)
              FilledButton(
                onPressed: onVerifyTap,
                child: const Text('Verifikasi'),
              ),
          ],
        ),
      ),
    );
  }
}

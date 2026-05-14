import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../auth/presentation/bloc/auth_bloc.dart';

/// Top-of-home banner that shows whichever verification step is still
/// missing. Soft gate: dismisses the banner once both flags are true,
/// but does NOT block access to home in either case.
class VerificationBanner extends StatelessWidget {
  const VerificationBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthBloc, AuthState>(
      buildWhen: (a, b) =>
          a.session?.emailVerified != b.session?.emailVerified ||
          a.session?.phoneNumberVerified != b.session?.phoneNumberVerified,
      builder: (context, state) {
        final session = state.session;
        if (session == null || session.fullyVerified) {
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final missing = <String>[
          if (!session.emailVerified) 'email',
          if (!session.phoneNumberVerified) 'nomor WhatsApp',
        ];
        final message = missing.length == 2
            ? 'Akun Anda belum diverifikasi.'
            : 'Verifikasi ${missing.first} Anda untuk membuka semua fitur.';
        return Material(
          color: scheme.errorContainer,
          child: InkWell(
            onTap: () => context.push('/verify'),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      message,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ),
                  Text(
                    'Verifikasi',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Icon(Icons.chevron_right, color: scheme.onErrorContainer),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

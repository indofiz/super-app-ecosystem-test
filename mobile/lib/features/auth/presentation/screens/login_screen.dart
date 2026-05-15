import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../l10n/app_localizations.dart';
import '../auth_error_l10n.dart';
import '../bloc/auth_bloc.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: BlocBuilder<AuthBloc, AuthState>(
              builder: (context, state) {
                final isLoading = state.status == AuthStatus.authenticating;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.shield_outlined, size: 64),
                    const SizedBox(height: 16),
                    Text(
                      'Smart App',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Pangkal Pinang',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 40),
                    if (state.errorCode != null) ...[
                      Text(
                        authErrorMessage(
                          AppLocalizations.of(context),
                          state.errorCode!,
                        ),
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      // audit-004 M-02: surface retryability so the user
                      // knows whether tapping the SSO button again is
                      // useful (timeout / cancelled / network) or whether
                      // they need out-of-band help (loginMissingFields,
                      // sessionExpired-on-restore, refreshFailed).
                      Text(
                        state.errorCode!.isRetryable
                            ? AppLocalizations.of(context).authRetryHint
                            : AppLocalizations.of(context).authPermanentHint,
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: isLoading
                            ? null
                            : () => context
                                .read<AuthBloc>()
                                .add(const AuthLoginRequested()),
                        icon: isLoading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.login),
                        label: Text(isLoading ? 'Signing in…' : 'Sign in with SSO'),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

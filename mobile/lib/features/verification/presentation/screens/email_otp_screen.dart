import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../bloc/verification_bloc.dart';
import '../verification_error_l10n.dart';
import '../widgets/otp_input.dart';
import '../widgets/resend_timer.dart';

/// Email OTP step. On entry, kicks off the send-OTP call immediately so
/// the user doesn't have to tap twice. Subsequent re-sends are gated by
/// the [ResendTimer].
class EmailOtpScreen extends StatefulWidget {
  const EmailOtpScreen({super.key});

  @override
  State<EmailOtpScreen> createState() => _EmailOtpScreenState();
}

class _EmailOtpScreenState extends State<EmailOtpScreen> {
  String _code = '';

  @override
  void initState() {
    super.initState();
    // audit-003 M-02: only auto-send when this channel has nothing in
    // flight or awaiting entry. The VerificationBloc is shared across the
    // whole /verify shell, so navigating back to /verify and re-entering
    // /verify/email must NOT fire a fresh send-OTP against a live code —
    // that let a crafted "reopen this route" deeplink pump unbounded
    // OTP-send requests at a victim (SMS/email-bombing). Manual resend
    // stays available via the ResendTimer.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final email = context.read<VerificationBloc>().state.email;
      if (email.status == ChannelStatus.idle) {
        context.read<VerificationBloc>().add(const EmailSendOtpRequested());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Verifikasi Email')),
      body: BlocConsumer<VerificationBloc, VerificationState>(
        listenWhen: (prev, curr) =>
            prev.email.status != curr.email.status &&
            curr.email.status == ChannelStatus.verified,
        listener: (context, state) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Email berhasil diverifikasi.')),
          );
          Navigator.of(context).pop();
        },
        builder: (context, state) {
          final email = state.email;
          final session = context.watch<AuthBloc>().state.session;
          final destination = session?.email ?? '—';
          final disabled = email.isBusy;
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Kami telah mengirim kode 6 digit ke',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  destination,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 32),
                OtpInput(
                  enabled: !disabled,
                  onChanged: (v) => setState(() => _code = v),
                  onCompleted: (v) => context
                      .read<VerificationBloc>()
                      .add(EmailVerifyOtpRequested(v)),
                ),
                const SizedBox(height: 16),
                if (email.errorCode != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      verificationErrorMessage(
                        AppLocalizations.of(context),
                        email.errorCode!,
                        attemptsLeft: email.attemptsLeft,
                      ),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: (disabled || _code.length != 6)
                        ? null
                        : () => context
                            .read<VerificationBloc>()
                            .add(EmailVerifyOtpRequested(_code)),
                    child: email.status == ChannelStatus.verifying
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Verifikasi'),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.center,
                  child: ResendTimer(
                    expiresAt: email.expiresAt,
                    enabled: !disabled,
                    onResend: () => context
                        .read<VerificationBloc>()
                        .add(const EmailSendOtpRequested()),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

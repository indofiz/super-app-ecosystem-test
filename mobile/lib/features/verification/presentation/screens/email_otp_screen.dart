import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../bloc/verification_bloc.dart';
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
  final _otpKey = GlobalKey<State>();
  String _code = '';

  @override
  void initState() {
    super.initState();
    // Fire-and-forget kickoff after the first frame so the bloc is
    // available via context. Idempotent on the BFF — if a prior code is
    // still valid, the server overwrites it, which is fine here.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<VerificationBloc>().add(const EmailSendOtpRequested());
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
                  key: _otpKey,
                  enabled: !disabled,
                  onChanged: (v) => setState(() => _code = v),
                  onCompleted: (v) => context
                      .read<VerificationBloc>()
                      .add(EmailVerifyOtpRequested(v)),
                ),
                const SizedBox(height: 16),
                if (email.errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      email.errorMessage!,
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

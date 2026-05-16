import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../bloc/verification_bloc.dart';
import '../verification_error_l10n.dart';
import '../widgets/otp_input.dart';
import '../widgets/resend_timer.dart';

/// WhatsApp OTP step. Structurally identical to [EmailOtpScreen]
/// (audit-003 M-03): there is no in-app phone-entry step. The BFF reads
/// the citizen's number from their Keycloak profile — the client never
/// supplies, edits, or even displays a number it holds itself; it shows
/// `session.phoneNumber` straight from the auth session (source of
/// record). On entry, kicks off send-OTP so the user doesn't tap twice;
/// re-sends are gated by the [ResendTimer].
class PhoneOtpScreen extends StatefulWidget {
  const PhoneOtpScreen({super.key});

  @override
  State<PhoneOtpScreen> createState() => _PhoneOtpScreenState();
}

class _PhoneOtpScreenState extends State<PhoneOtpScreen> {
  String _code = '';

  @override
  void initState() {
    super.initState();
    // audit-003 M-02: only auto-send when this channel has nothing in
    // flight or awaiting entry. The VerificationBloc is shared across the
    // whole /verify shell, so navigating back to /verify and re-entering
    // /verify/phone must NOT fire a fresh send-OTP against a live code —
    // that let a crafted "reopen this route" deeplink pump unbounded
    // OTP-send requests at a victim. Manual resend stays available via
    // the ResendTimer.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final phone = context.read<VerificationBloc>().state.phone;
      if (phone.status == ChannelStatus.idle) {
        context.read<VerificationBloc>().add(const PhoneSendOtpRequested());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Verifikasi WhatsApp')),
      body: BlocConsumer<VerificationBloc, VerificationState>(
        listenWhen: (prev, curr) =>
            prev.phone.status != curr.phone.status &&
            curr.phone.status == ChannelStatus.verified,
        listener: (context, state) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Nomor WhatsApp berhasil diverifikasi.'),
            ),
          );
          Navigator.of(context).pop();
        },
        builder: (context, state) {
          final phone = state.phone;
          final session = context.watch<AuthBloc>().state.session;
          final destination = session?.phoneNumber ?? '—';
          final disabled = phone.isBusy;
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Kami telah mengirim kode 6 digit via WhatsApp ke',
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
                      .add(PhoneVerifyOtpRequested(v)),
                ),
                const SizedBox(height: 16),
                if (phone.errorCode != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      verificationErrorMessage(
                        AppLocalizations.of(context),
                        phone.errorCode!,
                        attemptsLeft: phone.attemptsLeft,
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
                            .add(PhoneVerifyOtpRequested(_code)),
                    child: phone.status == ChannelStatus.verifying
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
                    expiresAt: phone.expiresAt,
                    enabled: !disabled,
                    onResend: () => context
                        .read<VerificationBloc>()
                        .add(const PhoneSendOtpRequested()),
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

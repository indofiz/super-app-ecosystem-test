import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../bloc/verification_bloc.dart';
import '../verification_error_l10n.dart';
import '../widgets/otp_input.dart';
import '../widgets/resend_timer.dart';

/// Two-step phone flow:
///   1. User enters their WhatsApp number in +62 format.
///   2. After send-OTP returns 202, the same screen swaps to the 6-digit
///      input. The BFF validates that the verifying phone matches the
///      issued one, so going back to step 1 forces a fresh OTP.
class PhoneOtpScreen extends StatefulWidget {
  const PhoneOtpScreen({super.key});

  @override
  State<PhoneOtpScreen> createState() => _PhoneOtpScreenState();
}

class _PhoneOtpScreenState extends State<PhoneOtpScreen> {
  // Controller holds digits-only (post-country-code). The `+62` is fixed
  // chrome on the input and re-attached at dispatch time. This kills the
  // truncation footgun where a user retyping `62` produced a silently
  // wrong number that Fonnte accepted but never delivered.
  final _phoneController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String _code = '';

  @override
  void initState() {
    super.initState();
    // Seed from the current session if one is already on file (e.g.
    // re-entering after a failed verify). Strip whatever country-code
    // form the session stores so the controller stays digits-only.
    final session = context.read<AuthBloc>().state.session;
    final existing = session?.phoneNumber;
    if (existing != null && existing.isNotEmpty) {
      _phoneController.text = _stripCountryCode(existing);
    }
  }

  static String _stripCountryCode(String input) {
    if (input.startsWith('+62')) return input.substring(3);
    if (input.startsWith('62')) return input.substring(2);
    return input;
  }

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
          final showCodeStep = phone.status == ChannelStatus.awaitingCode ||
              phone.status == ChannelStatus.verifying;
          return Padding(
            padding: const EdgeInsets.all(24),
            child: showCodeStep
                ? _codeStep(context, phone)
                : _phoneStep(context, phone),
          );
        },
      ),
    );
  }

  Widget _phoneStep(BuildContext context, ChannelState phone) {
    final theme = Theme.of(context);
    final disabled = phone.isBusy;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Masukkan nomor WhatsApp Anda',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Masukkan 8–12 digit setelah +62 (contoh: 81234567890)',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          TextFormField(
            controller: _phoneController,
            enabled: !disabled,
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(12),
            ],
            decoration: const InputDecoration(
              labelText: 'Nomor WhatsApp',
              prefixText: '+62 ',
              border: OutlineInputBorder(),
            ),
            validator: (v) {
              if (v == null || !RegExp(r'^\d{8,12}$').hasMatch(v)) {
                return 'Masukkan 8–12 digit setelah +62';
              }
              return null;
            },
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
              onPressed: disabled
                  ? null
                  : () {
                      if (_formKey.currentState?.validate() != true) return;
                      context.read<VerificationBloc>().add(
                            PhoneSendOtpRequested('+62${_phoneController.text}'),
                          );
                    },
              child: phone.status == ChannelStatus.sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Kirim Kode'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _codeStep(BuildContext context, ChannelState phone) {
    final theme = Theme.of(context);
    final disabled = phone.isBusy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Kami telah mengirim kode 6 digit via WhatsApp ke',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 4),
        Text(
          phone.phoneNumber ?? '—',
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
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton.icon(
              onPressed: disabled
                  ? null
                  : () {
                      // Reset back to step 1 by clearing the channel
                      // state's expiresAt (via a fresh send when user
                      // chooses to). Simplest: pop and re-enter.
                      Navigator.of(context).pop();
                    },
              icon: const Icon(Icons.edit, size: 18),
              label: const Text('Ubah nomor'),
            ),
            ResendTimer(
              expiresAt: phone.expiresAt,
              enabled: !disabled,
              onResend: () {
                final number = phone.phoneNumber;
                if (number != null) {
                  context
                      .read<VerificationBloc>()
                      .add(PhoneSendOtpRequested(number));
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

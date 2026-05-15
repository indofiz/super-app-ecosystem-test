import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/config/auth_timings.dart';

/// "Kirim ulang dalam 0:42" / "Kirim ulang kode" toggle.
///
/// Counts down toward [expiresAt] (or a fixed [resendCooldown] from now
/// if [expiresAt] is null). When the timer hits zero, swaps to a
/// tappable "Kirim ulang" button.
class ResendTimer extends StatefulWidget {
  const ResendTimer({
    super.key,
    this.expiresAt,
    this.resendCooldown = kOtpResendCooldown,
    required this.onResend,
    this.enabled = true,
  });

  /// When set, the countdown ticks toward this instant. Used for the
  /// OTP TTL window (5 min from issue). When null, the timer counts
  /// down [resendCooldown] from `initState`.
  final DateTime? expiresAt;
  final Duration resendCooldown;
  final VoidCallback onResend;
  final bool enabled;

  @override
  State<ResendTimer> createState() => _ResendTimerState();
}

class _ResendTimerState extends State<ResendTimer> {
  Timer? _ticker;
  late DateTime _target;

  @override
  void initState() {
    super.initState();
    _target = widget.expiresAt ?? DateTime.now().add(widget.resendCooldown);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant ResendTimer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expiresAt != oldWidget.expiresAt) {
      _target = widget.expiresAt ?? DateTime.now().add(widget.resendCooldown);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _target.difference(DateTime.now());
    if (remaining.isNegative || remaining == Duration.zero) {
      return TextButton.icon(
        onPressed: widget.enabled ? widget.onResend : null,
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text('Kirim ulang kode'),
      );
    }
    final m = remaining.inMinutes.remainder(60).toString();
    final s = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    return Text(
      'Kirim ulang dalam $m:$s',
      style: Theme.of(context).textTheme.bodyMedium,
    );
  }
}

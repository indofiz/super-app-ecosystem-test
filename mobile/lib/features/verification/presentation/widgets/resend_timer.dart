import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/config/auth_timings.dart';

/// "Kirim ulang dalam 0:42" / "Kirim ulang kode" toggle.
///
/// Counts down toward [expiresAt] (or a fixed [resendCooldown] from now
/// if [expiresAt] is null). When the timer hits zero, swaps to a
/// tappable "Kirim ulang" button.
///
/// audit-004 M-05: the countdown is driven by a monotonic [Stopwatch],
/// not by reading the wall clock on every tick. We take **one**
/// `DateTime.now()` reading at `initState` (or when `expiresAt` changes)
/// to compute the initial duration; from then on, every tick decrements
/// against `Stopwatch.elapsed`. This makes the timer robust to:
///   - device-clock skew (NITZ off, traveller, automatic-time-off),
///   - manual clock adjustments mid-countdown,
///   - DST rollover.
/// The trade-off is that we trust the wall clock for the initial offset
/// only — which is unavoidable, since the server-issued `expiresAt` is
/// itself anchored to wall-clock time.
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
  late Duration _initialRemaining;
  final Stopwatch _stopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    _initialRemaining = _computeInitial();
    _stopwatch.start();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  /// Single wall-clock read. After this point the widget is driven by
  /// `_stopwatch.elapsed` — a monotonic source the user cannot perturb.
  Duration _computeInitial() {
    final exp = widget.expiresAt;
    if (exp == null) return widget.resendCooldown;
    final initial = exp.difference(DateTime.now());
    return initial.isNegative ? Duration.zero : initial;
  }

  @override
  void didUpdateWidget(covariant ResendTimer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expiresAt != oldWidget.expiresAt) {
      _initialRemaining = _computeInitial();
      _stopwatch
        ..reset()
        ..start();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _stopwatch.stop();
    super.dispose();
  }

  Duration get _remaining {
    final r = _initialRemaining - _stopwatch.elapsed;
    return r.isNegative ? Duration.zero : r;
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _remaining;
    if (remaining == Duration.zero) {
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

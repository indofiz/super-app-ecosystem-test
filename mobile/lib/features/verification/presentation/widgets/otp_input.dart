import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Simple 6-digit OTP entry. Single underlying TextField with per-digit
/// boxes painted on top — keeps keyboard handling boringly correct
/// (paste, autofill, IME) without a focus-juggling controller-array.
///
/// Fires [onCompleted] when the 6th digit lands. The wrapping screen
/// owns the submit flow; this widget just collects digits.
class OtpInput extends StatefulWidget {
  const OtpInput({
    super.key,
    this.length = 6,
    this.autofocus = true,
    this.enabled = true,
    this.onChanged,
    this.onCompleted,
  });

  final int length;
  final bool autofocus;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onCompleted;

  @override
  State<OtpInput> createState() => _OtpInputState();
}

class _OtpInputState extends State<OtpInput> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _focusNode = FocusNode();
    _controller.addListener(_onChange);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChange() {
    final v = _controller.text;
    widget.onChanged?.call(v);
    if (v.length == widget.length) {
      widget.onCompleted?.call(v);
    }
  }

  /// Clears the input — called by the parent when an error wipes the field.
  void clear() => _controller.clear();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Single logical semantic node — screen readers announce one
    // "OTP code" text field instead of an underlying TextField *and* six
    // unlabeled boxes. The painted overlay below is `ExcludeSemantics`d
    // so it does not introduce noise.
    return Semantics(
      label: 'OTP code',
      textField: true,
      child: GestureDetector(
        onTap: () {
          if (widget.enabled) _focusNode.requestFocus();
        },
        child: Stack(
          children: [
            // Invisible TextField captures input. Opacity=0.01 keeps the
            // platform IME / autofill heuristics working — fully transparent
            // widgets are sometimes ignored by autofill engines.
            Opacity(
              opacity: 0.01,
              child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: widget.autofocus,
              enabled: widget.enabled,
              keyboardType: TextInputType.number,
              maxLength: widget.length,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  counterText: '',
                  border: InputBorder.none,
                ),
              ),
            ),
            ExcludeSemantics(
              child: IgnorePointer(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: List.generate(widget.length, (i) {
                    final v = _controller.text;
                    final ch = i < v.length ? v[i] : '';
                    final isCursor = i == v.length && _focusNode.hasFocus;
                    return Container(
                      width: 44,
                      height: 56,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isCursor
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                          width: isCursor ? 2 : 1,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        ch,
                        style: theme.textTheme.headlineSmall,
                      ),
                    );
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

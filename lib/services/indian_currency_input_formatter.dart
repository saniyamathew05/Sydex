import 'package:flutter/services.dart';

/// Formats numeric input using Indian digit grouping while keeping decimal input usable.
class IndianCurrencyInputFormatter extends TextInputFormatter {
  const IndianCurrencyInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text.replaceAll(',', '').replaceAll('₹', '').trim();
    if (raw.isEmpty) return newValue.copyWith(text: '');
    if (!RegExp(r'^\d*\.?\d*$').hasMatch(raw)) return oldValue;

    final parts = raw.split('.');
    final integerPart = parts.first;
    final decimalPart = parts.length > 1 ? parts[1] : null;
    final formattedInteger = _groupIndian(integerPart);
    final formatted = decimalPart == null
        ? formattedInteger
        : '$formattedInteger.$decimalPart';
    final digitsBeforeCursor = newValue.text
        .substring(
          0,
          newValue.selection.baseOffset.clamp(0, newValue.text.length),
        )
        .replaceAll(',', '')
        .length;
    var cursor = 0;
    var digitsSeen = 0;
    while (cursor < formatted.length && digitsSeen < digitsBeforeCursor) {
      if (formatted[cursor] != ',') digitsSeen++;
      cursor++;
    }
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: cursor),
      composing: TextRange.empty,
    );
  }

  String _groupIndian(String digits) {
    if (digits.length <= 3) return digits;
    final lastThree = digits.substring(digits.length - 3);
    var leading = digits.substring(0, digits.length - 3);
    final groups = <String>[];
    while (leading.length > 2) {
      groups.insert(0, leading.substring(leading.length - 2));
      leading = leading.substring(0, leading.length - 2);
    }
    if (leading.isNotEmpty) groups.insert(0, leading);
    return '${groups.join(',')},$lastThree';
  }
}

/// Currency formatting for LedgerPro, including Indian digit grouping for INR.
class CurrencyFormatter {
  CurrencyFormatter._();

  static const Map<String, int> _decimalDigits = {
    'BIF': 0,
    'CLP': 0,
    'DJF': 0,
    'GNF': 0,
    'ISK': 0,
    'JPY': 0,
    'KMF': 0,
    'KRW': 0,
    'PYG': 0,
    'RWF': 0,
    'UGX': 0,
    'VND': 0,
    'VUV': 0,
    'XAF': 0,
    'XOF': 0,
    'XPF': 0,
    'BHD': 3,
    'IQD': 3,
    'JOD': 3,
    'KWD': 3,
    'LYD': 3,
    'OMR': 3,
    'TND': 3,
  };

  static const Map<String, String> _symbols = {
    'INR': '₹',
    'USD': r'$',
    'EUR': '€',
    'GBP': '£',
    'JPY': '¥',
    'CNY': '¥',
    'KRW': '₩',
    'AUD': r'A$',
    'CAD': r'C$',
    'SGD': r'S$',
    'AED': 'د.إ',
    'SAR': '﷼',
  };

  static String format(
    num value, {
    String currencyCode = 'INR',
    int? decimals,
    bool showSymbol = true,
  }) {
    final code = currencyCode.trim().toUpperCase();
    final digits = (decimals ?? _decimalDigits[code] ?? 2).clamp(0, 6);
    final fixed = value.abs().toStringAsFixed(digits).split('.');
    final integer = code == 'INR'
        ? _groupIndian(fixed[0])
        : _groupWestern(fixed[0]);
    final fraction = fixed.length > 1 ? '.${fixed[1]}' : '';
    final amount = '${value < 0 ? '-' : ''}$integer$fraction';
    if (!showSymbol) return amount;
    final symbol = _symbols[code];
    return symbol == null ? '$code $amount' : '$symbol$amount';
  }

  static String rupees(num value, {int decimals = 2}) =>
      format(value, currencyCode: 'INR', decimals: decimals);

  static String customerBalance(num balance) => balance < 0
      ? 'Owed to customer: ${rupees(balance.abs())}'
      : 'Amount due: ${rupees(balance)}';

  /// Formats a ledger balance without displaying an unexplained negative.
  /// Negative balances represent customer credit/advance, not money due.
  static String balanceAfter(num balance) =>
      balance < 0 ? 'Advance: ${rupees(balance.abs())}' : rupees(balance);

  static String _groupIndian(String digits) {
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

  static String _groupWestern(String digits) {
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }
}

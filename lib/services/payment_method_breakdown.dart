import 'currency_formatter.dart';

/// Reads the compact method allocation saved in a payment's method note.
class PaymentMethodBreakdown {
  static const marker = 'Split amounts:';

  static List<({String method, double amount})> parseOrdered(String? note) {
    if (note == null || !note.contains(marker)) return const [];
    final section = note.split(marker).last.split(' • ').first;
    final result = <({String method, double amount})>[];
    for (final part in section.split(';')) {
      final pair = part.trim().split('=');
      if (pair.length != 2) continue;
      final amount = double.tryParse(pair[1].trim());
      final method = pair[0].trim().toLowerCase();
      if (amount != null && method.isNotEmpty) {
        result.add((method: method, amount: amount));
      }
    }
    return result;
  }

  static Map<String, double> parse(String? note) {
    final result = <String, double>{};
    for (final entry in parseOrdered(note)) {
      result[entry.method] = entry.amount;
    }
    return result;
  }

  static bool includes(String? note, String method) =>
      parse(note).containsKey(method.toLowerCase());

  static String methodLabel(String method) {
    switch (method.trim().toLowerCase()) {
      case 'cash':
        return 'Cash';
      case 'cheque':
        return 'Cheque';
      case 'neft':
        return 'NEFT';
      case 'gpay':
        return 'GPay';
    }
    return method
        .split('_')
        .map(
          (part) => part.isEmpty
              ? part
              : '${part[0].toUpperCase()}${part.substring(1)}',
        )
        .join(' ');
  }

  /// One "Method ₹amount" line per method used in a split payment, or an
  /// empty list when the payment used a single method.
  static List<String> lines(String? note) => parseOrdered(note)
      .map(
        (entry) =>
            '${methodLabel(entry.method)} ${CurrencyFormatter.rupees(entry.amount)}',
      )
      .toList(growable: false);

  static String? display(String? note) {
    final parts = lines(note);
    return parts.isEmpty ? null : parts.join(' + ');
  }

  static String? additionalNote(String? note) {
    if (note == null || !note.contains(marker)) return note;
    final parts = note.split(' • ');
    return parts.length > 1 ? parts.skip(1).join(' • ').trim() : null;
  }

  static double amountFor({
    required String? note,
    required String method,
    required double fallbackAmount,
  }) => parse(note)[method.toLowerCase()] ?? fallbackAmount;
}

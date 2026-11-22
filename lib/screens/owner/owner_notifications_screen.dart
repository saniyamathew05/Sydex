import 'package:flutter/material.dart';

import '../../services/transaction_service.dart';
import '../../services/currency_formatter.dart';
import '../../services/notification_read_store.dart';
import '../../widgets/sydex_ui.dart';

class OwnerNotificationsScreen extends StatefulWidget {
  const OwnerNotificationsScreen({super.key});

  @override
  State<OwnerNotificationsScreen> createState() =>
      _OwnerNotificationsScreenState();
}

class _OwnerNotificationsScreenState extends State<OwnerNotificationsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final payments = TransactionService.transactions.where(
        (t) => !t.isBounced,
      );
      await NotificationReadStore.markSeen(
        payments.map((payment) => payment.id),
      );
    });
  }

  String _when(DateTime date) {
    final local = date.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final time =
        '${local.hour % 12 == 0 ? 12 : local.hour % 12}:${local.minute.toString().padLeft(2, '0')} ${local.hour < 12 ? 'am' : 'pm'}';
    if (day == today) return 'Today · $time';
    if (day == today.subtract(const Duration(days: 1))) {
      return 'Yesterday · $time';
    }
    return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}/${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final payments =
        TransactionService.transactions.where((t) => !t.isBounced).toList()
          ..sort(
            (a, b) => (b.createdAt ?? b.transactionDate).compareTo(
              a.createdAt ?? a.transactionDate,
            ),
          );
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: SydexPageList(
          maxWidth: 860,
          top: 14,
          children: [
            SydexScreenHeader(
              eyebrow: 'Payment and account notifications',
              title: 'Notifications',
              leading: Navigator.of(context).canPop()
                  ? SydexIconButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: 'Back',
                      onPressed: () => Navigator.of(context).maybePop(),
                    )
                  : null,
            ),
            const SizedBox(height: 18),
            if (payments.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 80),
                child: Column(
                  children: [
                    Icon(
                      Icons.notifications_none_rounded,
                      size: 42,
                      color: colors.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No notifications yet.',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              )
            else
              SydexReveal(
                child: SydexCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      for (var i = 0; i < payments.length; i++) ...[
                        if (i > 0)
                          Divider(height: 1, color: colors.outlineVariant),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Payment received from ${payments[i].customerName}',
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${payments[i].reference} · ${payments[i].receivedBy}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _when(
                                        payments[i].createdAt ??
                                            payments[i].transactionDate,
                                      ),
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                '+${CurrencyFormatter.rupees(payments[i].actualAmountReceived)}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: colors.secondary,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

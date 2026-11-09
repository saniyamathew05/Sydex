import 'package:flutter/material.dart';

import '../../services/transaction_service.dart';
import '../../services/currency_formatter.dart';
import '../../services/notification_read_store.dart';

class OwnerNotificationsScreen extends StatefulWidget {
  const OwnerNotificationsScreen({super.key});

  @override
  State<OwnerNotificationsScreen> createState() => _OwnerNotificationsScreenState();
}

class _OwnerNotificationsScreenState extends State<OwnerNotificationsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final payments = TransactionService.transactions.where((t) => !t.isBounced);
      await NotificationReadStore.markSeen(payments.map((payment) => payment.id));
    });
  }

  @override
  Widget build(BuildContext context) {
    final payments =
        TransactionService.transactions.where((t) => !t.isBounced).toList()
          ..sort(
            (a, b) => (b.createdAt ?? b.transactionDate).compareTo(
              a.createdAt ?? a.transactionDate,
            ),
          );
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: payments.isEmpty
          ? const Center(child: Text('No notifications yet.'))
          : ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: payments.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final payment = payments[index];
                return Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.payments_outlined),
                    ),
                    title: Text(
                      'Payment received from ${payment.customerName}',
                    ),
                    subtitle: Text(
                      '${payment.reference} • ${payment.receivedBy}',
                    ),
                    trailing: Text(
                      '+${CurrencyFormatter.rupees(payment.actualAmountReceived)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Colors.green,
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

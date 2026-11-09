import 'package:flutter/material.dart';
import 'dart:async';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../services/subscription_service.dart';

class SubscriptionBillingScreen extends StatefulWidget {
  const SubscriptionBillingScreen({super.key});

  @override
  State<SubscriptionBillingScreen> createState() =>
      _SubscriptionBillingScreenState();
}

class _SubscriptionBillingScreenState extends State<SubscriptionBillingScreen> {
  late Future<SubscriptionEntitlement> _future;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;

  @override
  void initState() {
    super.initState();
    _future = SubscriptionService.loadEntitlement();
    final updates = SubscriptionService.androidPurchaseUpdates;
    if (updates != null) {
      _purchaseSubscription = updates.listen((purchases) async {
        for (final purchase in purchases) {
          try {
            await SubscriptionService.submitPurchaseForVerification(purchase);
          } catch (_) {
            // Verification remains fail-closed; retry when the screen reloads.
          }
        }
        if (mounted) setState(() => _future = SubscriptionService.loadEntitlement());
      });
    }
  }

  @override
  void dispose() {
    _purchaseSubscription?.cancel();
    super.dispose();
  }

  String _date(DateTime? value) {
    if (value == null) return 'Not available';
    final local = value.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}/${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Subscription & Billing')),
      body: FutureBuilder<SubscriptionEntitlement>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            if (snapshot.hasError) {
              return Center(child: Text('Could not load billing status: ${snapshot.error}'));
            }
            return const Center(child: CircularProgressIndicator());
          }
          final entitlement = snapshot.data!;
          final isAndroid = SubscriptionService.supportsGooglePlay;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Icon(Icons.workspace_premium_rounded,
                  size: 54, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              Text(entitlement.planCode == 'free' ? 'Free plan' : entitlement.planCode,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _row('Status', entitlement.status),
                    _row('Renewal date', _date(entitlement.renewsAt)),
                    _row('Workspace access', entitlement.isActive ? 'Enabled' : 'Not active'),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                isAndroid
                    ? 'Subscriptions purchased through Google Play are verified by Sydex before workspace access is enabled.'
                    : 'Manage this workspace subscription in the Google Play Store app on the Android device that was used to subscribe. Windows does not start Google Play billing or ask you to pay again.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              if (entitlement.canManageBilling) ...[
                const SizedBox(height: 12),
                Text('Only the workspace Owner manages billing. Authorized Salesman accounts inherit the workspace entitlement.',
                    style: Theme.of(context).textTheme.bodyMedium),
                if (isAndroid && !entitlement.isActive) ...[
                  const SizedBox(height: 14),
                  Text('Choose a Google Play plan', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  _planButton(context, 'Monthly', '₹299/month', SubscriptionService.monthlyBasePlanId),
                  _planButton(context, 'Yearly', '₹2,999/year', SubscriptionService.yearlyBasePlanId),
                  TextButton.icon(
                    onPressed: () async {
                      await SubscriptionService.restoreGooglePlayPurchases();
                      if (!context.mounted) return;
                      setState(() => _future = SubscriptionService.loadEntitlement());
                    },
                    icon: const Icon(Icons.restore),
                    label: const Text('Restore purchases'),
                  ),
                  const Text('Google Play will show the final localized price and whether the 14-day trial is available for this account. Subscriptions renew automatically unless canceled in Google Play.'),
                ],
              ],
              if (isAndroid) ...[
                const SizedBox(height: 12),
                const Text('By subscribing, you agree to the Sydex Terms of Service and Privacy Policy.'),
              ],
              const SizedBox(height: 16),
              const Text('Payment verification is being rolled out safely. Existing customers are not blocked while provider verification is configured and tested.'),
            ],
          );
        },
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          Flexible(child: Text(value, textAlign: TextAlign.end)),
        ]),
      );

  Widget _planButton(BuildContext context, String title, String fallbackPrice, String basePlanId) {
    return OutlinedButton(
      onPressed: () async {
        final started = await SubscriptionService.purchaseGooglePlayPlan(basePlanId);
        if (!context.mounted || started) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$title is not available in Google Play for this account yet.')),
        );
      },
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(title),
        Text(fallbackPrice),
      ]),
    );
  }
}

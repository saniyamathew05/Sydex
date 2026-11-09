import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SubscriptionEntitlement {
  const SubscriptionEntitlement({
    required this.planCode,
    required this.status,
    required this.canManageBilling,
    required this.paywallEnabled,
    this.renewsAt,
    this.provider,
    this.platform,
  });

  final String planCode;
  final String status;
  final bool canManageBilling;
  final bool paywallEnabled;
  final DateTime? renewsAt;
  final String? provider;
  final String? platform;

  bool get isActive => status == 'active';
  bool get isConfigured => provider != null && provider!.isNotEmpty;

  factory SubscriptionEntitlement.fromMap(Map<String, dynamic> map) {
    final rawDate = map['renews_at']?.toString();
    return SubscriptionEntitlement(
      planCode: map['plan_code']?.toString() ?? 'free',
      status: map['status']?.toString() ?? 'inactive',
      canManageBilling: map['can_manage_billing'] == true,
      paywallEnabled: map['paywall_enabled'] == true,
      renewsAt: rawDate == null ? null : DateTime.tryParse(rawDate),
      provider: map['provider']?.toString(),
      platform: map['platform']?.toString(),
    );
  }
}

class SubscriptionService {
  SubscriptionService._();
  static final _supabase = Supabase.instance.client;
  static final _iap = InAppPurchase.instance;
  static const productId = 'sydex_premium';
  static const monthlyBasePlanId = 'monthly';
  static const yearlyBasePlanId = 'yearly';

  static bool get supportsGooglePlay =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<SubscriptionEntitlement> loadEntitlement() async {
    final rows = await _supabase.rpc('get_my_subscription_entitlement');
    final list = rows is List ? rows : const [];
    if (list.isEmpty) {
      return const SubscriptionEntitlement(
        planCode: 'free',
        status: 'inactive',
        canManageBilling: false,
        paywallEnabled: false,
      );
    }
    return SubscriptionEntitlement.fromMap(
      Map<String, dynamic>.from(list.first as Map),
    );
  }

  /// Starts the Android purchase listener only on Android. Verification and
  /// entitlement changes happen in Supabase; the client never grants access.
  static Stream<List<PurchaseDetails>>? get androidPurchaseUpdates {
    if (!supportsGooglePlay) return null;
    return _iap.purchaseStream;
  }

  static Future<bool> isGooglePlayAvailable() async {
    if (!supportsGooglePlay) return false;
    try {
      return await _iap.isAvailable();
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> startGooglePlayPurchase() async {
    return purchaseGooglePlayPlan(monthlyBasePlanId);
  }

  static Future<bool> purchaseGooglePlayPlan(String basePlanId) async {
    if (!supportsGooglePlay || !await isGooglePlayAvailable()) return false;
    final response = await _iap.queryProductDetails({productId});
    if (response.productDetails.isEmpty) return false;
    final matchingProducts = response.productDetails
        .whereType<GooglePlayProductDetails>()
        .where((candidate) => candidate.productDetails.subscriptionOfferDetails
            ?.any((offer) => offer.basePlanId == basePlanId) == true)
        .toList();
    if (matchingProducts.isEmpty) return false;
    final product = matchingProducts.first;
    final offer = product.productDetails.subscriptionOfferDetails!
        .firstWhere((candidate) => candidate.basePlanId == basePlanId);
    final purchaseParam = GooglePlayPurchaseParam(
      productDetails: product,
      offerToken: offer.offerIdToken,
    );
    return _iap.buyNonConsumable(purchaseParam: purchaseParam);
  }

  static Future<void> restoreGooglePlayPurchases() async {
    if (supportsGooglePlay) await _iap.restorePurchases();
  }

  static Future<void> submitPurchaseForVerification(PurchaseDetails purchase) async {
    if (!supportsGooglePlay || purchase.productID != productId) return;
    await _supabase.functions.invoke(
      'verify-google-play-subscription',
      body: {
        'product_id': purchase.productID,
        'purchase_id': purchase.purchaseID,
        'verification_data': purchase.verificationData.serverVerificationData,
        'status': purchase.status.name,
      },
    );
    if (purchase.pendingCompletePurchase) await _iap.completePurchase(purchase);
  }
}

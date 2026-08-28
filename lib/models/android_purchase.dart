import 'dart:convert';

import 'mantra.dart';
import '../services/play_billing_service.dart';

final class AndroidCartProduct {
  const AndroidCartProduct({
    required this.internalProductId,
    required this.productName,
    required this.storeProductId,
    required this.quantity,
  });

  final String internalProductId;
  final String productName;
  final String storeProductId;
  final int quantity;

  Map<String, dynamic> toPrepareJson() => {
    'productId': internalProductId,
    'productName': productName,
    'quantity': quantity,
  };

  Map<String, dynamic> toJson() => {
    ...toPrepareJson(),
    'storeProductId': storeProductId,
  };

  factory AndroidCartProduct.fromJson(Map<String, dynamic> json) {
    return AndroidCartProduct(
      internalProductId: json['productId']?.toString() ?? '',
      productName: json['productName']?.toString() ?? '',
      storeProductId: json['storeProductId']?.toString() ?? '',
      quantity: _positiveInt(json['quantity']),
    );
  }
}

List<AndroidCartProduct> aggregateAndroidCart(Iterable<Mantra> items) {
  final products = <String, AndroidCartProduct>{};
  for (final mantra in items) {
    final internalId = mantra.internalProductId;
    final storeId = mantra.storeProductIdAndroid?.trim() ?? '';
    if (internalId.isEmpty || storeId.isEmpty) continue;
    final existing = products[internalId];
    if (existing != null && existing.storeProductId != storeId) {
      throw StateError('Conflicting Google Play mapping for $internalId');
    }
    products[internalId] = AndroidCartProduct(
      internalProductId: internalId,
      productName: mantra.name,
      storeProductId: storeId,
      quantity: 1,
    );
  }
  return products.values.toList(growable: false);
}

int? googlePlayCartTotalMicros(
  Iterable<AndroidCartProduct> products,
  Map<String, PlayProductPrice> prices,
) {
  String? currency;
  var total = 0;
  for (final item in products) {
    final price = prices[item.storeProductId];
    if (price == null || item.quantity < 1) return null;
    if (currency != null && currency != price.currencyCode) return null;
    currency = price.currencyCode;
    total += price.priceAmountMicros * item.quantity;
  }
  return currency == null ? null : total;
}

final class PreparedStoreProduct {
  const PreparedStoreProduct({
    required this.storeProductId,
    required this.quantity,
    this.internalProductId,
  });

  final String storeProductId;
  final int quantity;
  final String? internalProductId;

  factory PreparedStoreProduct.fromJson(Map<String, dynamic> json) {
    return PreparedStoreProduct(
      storeProductId:
          (json['storeProductId'] ??
                  json['store_product_id'] ??
                  json['productId'])
              ?.toString()
              .trim() ??
          '',
      quantity: _positiveInt(json['quantity']),
      internalProductId:
          (json['internalProductId'] ?? json['internal_product_id'])
              ?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'storeProductId': storeProductId,
    'quantity': quantity,
    if (internalProductId != null) 'internalProductId': internalProductId,
  };
}

final class PreparedPurchase {
  const PreparedPurchase({
    required this.orderId,
    required this.linkToken,
    required this.storeProducts,
  });

  final String orderId;
  final String linkToken;
  final List<PreparedStoreProduct> storeProducts;

  factory PreparedPurchase.fromJson(Map<String, dynamic> body) {
    final data = _responseData(body);
    final rawProducts = data['storeProducts'] ?? data['store_products'];
    final products = rawProducts is List
        ? rawProducts
              .whereType<Map>()
              .map(
                (item) => PreparedStoreProduct.fromJson(
                  Map<String, dynamic>.from(item),
                ),
              )
              .toList(growable: false)
        : const <PreparedStoreProduct>[];
    final purchase = PreparedPurchase(
      orderId: (data['orderId'] ?? data['order_id'])?.toString().trim() ?? '',
      linkToken:
          (data['linkToken'] ?? data['link_token'])?.toString().trim() ?? '',
      storeProducts: products,
    );
    if (purchase.orderId.isEmpty ||
        purchase.linkToken.isEmpty ||
        purchase.storeProducts.isEmpty ||
        purchase.storeProducts.any(
          (product) => product.storeProductId.isEmpty || product.quantity < 1,
        )) {
      throw const FormatException('Invalid prepare-purchase response');
    }
    return purchase;
  }
}

final class PurchaseVerification {
  const PurchaseVerification({required this.status, this.orderId});

  final String status;
  final String? orderId;
  bool get accepted => status == 'partially_paid' || status == 'paid';
  bool get paid => status == 'paid';
  bool get terminal => const {
    'cancelled',
    'canceled',
    'refunded',
    'expired',
    'failed',
  }.contains(status);

  factory PurchaseVerification.fromJson(Map<String, dynamic> body) {
    final data = _responseData(body);
    final order = data['order'] is Map
        ? Map<String, dynamic>.from(data['order'] as Map)
        : const <String, dynamic>{};
    return PurchaseVerification(
      status:
          (data['status'] ??
                  data['paymentStatus'] ??
                  data['payment_status'] ??
                  order['status'] ??
                  order['paymentStatus'] ??
                  '')
              .toString()
              .trim()
              .toLowerCase(),
      orderId: (data['orderId'] ?? data['order_id'])?.toString(),
    );
  }
}

final class AndroidPurchaseContext {
  const AndroidPurchaseContext({
    required this.orderId,
    required this.linkToken,
    required this.products,
    required this.verifiedStoreProductIds,
    required this.currentIndex,
    required this.state,
    required this.createdAt,
  });

  final String orderId;
  final String linkToken;
  final List<PreparedStoreProduct> products;
  final Set<String> verifiedStoreProductIds;
  final int currentIndex;
  final String state;
  final DateTime createdAt;

  Set<String> get storeProductIds =>
      products.map((product) => product.storeProductId).toSet();

  bool matchesCart(Iterable<AndroidCartProduct> cartProducts) {
    if (products.any((product) => product.quantity != 1)) return false;
    final cart = cartProducts.toList(growable: false);
    if (cart.any((product) => product.quantity != 1)) return false;
    final cartIds = cart.map((product) => product.storeProductId).toSet();
    return storeProductIds.length == products.length &&
        cartIds.length == cart.length &&
        _sameStringSet(storeProductIds, cartIds);
  }

  bool get isTerminal => const {
    'cancelled',
    'canceled',
    'refunded',
    'expired',
    'failed',
  }.contains(state.toLowerCase());

  AndroidPurchaseContext copyWith({
    Set<String>? verifiedStoreProductIds,
    int? currentIndex,
    String? state,
  }) => AndroidPurchaseContext(
    orderId: orderId,
    linkToken: linkToken,
    products: products,
    verifiedStoreProductIds:
        verifiedStoreProductIds ?? this.verifiedStoreProductIds,
    currentIndex: currentIndex ?? this.currentIndex,
    state: state ?? this.state,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson({bool includeLinkToken = true}) => {
    'orderId': orderId,
    if (includeLinkToken) 'linkToken': linkToken,
    'products': products.map((item) => item.toJson()).toList(),
    'verifiedStoreProductIds': verifiedStoreProductIds.toList(),
    'currentIndex': currentIndex,
    'state': state,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory AndroidPurchaseContext.fromJson(
    Map<String, dynamic> json, {
    required String linkToken,
  }) {
    final products = (json['products'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) =>
              PreparedStoreProduct.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false);
    return AndroidPurchaseContext(
      orderId: json['orderId']?.toString() ?? '',
      linkToken: linkToken,
      products: products,
      verifiedStoreProductIds:
          (json['verifiedStoreProductIds'] as List? ?? const [])
              .map((item) => item.toString())
              .toSet(),
      currentIndex: int.tryParse(json['currentIndex']?.toString() ?? '') ?? 0,
      state: json['state']?.toString() ?? 'prepared',
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now().toUtc(),
    );
  }

  String encodeWithoutToken() => jsonEncode(toJson(includeLinkToken: false));
}

Map<String, dynamic> _responseData(Map<String, dynamic> body) {
  final data = body['data'];
  return data is Map ? Map<String, dynamic>.from(data) : body;
}

void validatePlayLaunch({
  required AndroidPurchaseContext context,
  required Iterable<AndroidCartProduct> visibleCart,
}) {
  final visible = visibleCart.toList(growable: false);
  if (!context.matchesCart(visible)) {
    throw StateError('Active purchase order does not match the visible cart');
  }
  if (context.isTerminal) throw StateError('Purchase order is terminal');
  if (context.products.any((product) => product.quantity != 1)) {
    throw StateError('Android purchase quantity must be one');
  }
  if (context.storeProductIds.length != context.products.length) {
    throw StateError('Google Play product IDs must be unique');
  }
}

bool purchaseProductsMatch(
  AndroidPurchaseContext context,
  PlayPurchase purchase,
) {
  final actual = purchase.products.toSet();
  return actual.length == purchase.products.length &&
      _sameStringSet(context.storeProductIds, actual);
}

enum AndroidRecoveryAction {
  abandonUnownedPreparedOrder,
  reconcilePendingPurchase,
  reconcilePurchasedPurchase,
  retainOutstandingPurchase,
  retainVerifiedContext,
}

final class AndroidRecoveryDecision {
  const AndroidRecoveryDecision({required this.action, this.matchingPurchase});

  final AndroidRecoveryAction action;
  final PlayPurchase? matchingPurchase;

  bool get shouldAbandon =>
      action == AndroidRecoveryAction.abandonUnownedPreparedOrder;
}

AndroidRecoveryDecision decideAndroidRecovery({
  required AndroidPurchaseContext context,
  required Iterable<PlayPurchase> outstandingPurchases,
}) {
  final matching = outstandingPurchases.where(
    (purchase) =>
        purchaseProductsMatch(context, purchase) &&
        (purchase.obfuscatedAccountId == null ||
            purchase.obfuscatedAccountId == context.linkToken),
  );
  if (matching.isNotEmpty) {
    final purchase = matching.first;
    if (purchase.isPending && purchase.purchaseToken.isNotEmpty) {
      return AndroidRecoveryDecision(
        action: AndroidRecoveryAction.reconcilePendingPurchase,
        matchingPurchase: purchase,
      );
    }
    if (purchase.isPurchased && purchase.purchaseToken.isNotEmpty) {
      return AndroidRecoveryDecision(
        action: AndroidRecoveryAction.reconcilePurchasedPurchase,
        matchingPurchase: purchase,
      );
    }
    return AndroidRecoveryDecision(
      action: AndroidRecoveryAction.retainOutstandingPurchase,
      matchingPurchase: purchase,
    );
  }
  if (context.state == 'verified_pending_consumption' ||
      context.verifiedStoreProductIds.isNotEmpty) {
    return const AndroidRecoveryDecision(
      action: AndroidRecoveryAction.retainVerifiedContext,
    );
  }
  return const AndroidRecoveryDecision(
    action: AndroidRecoveryAction.abandonUnownedPreparedOrder,
  );
}

bool _sameStringSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

int _positiveInt(Object? value) {
  final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
  return parsed == null || parsed < 1 ? 1 : parsed;
}

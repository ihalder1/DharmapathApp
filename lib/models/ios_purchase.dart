import 'dart:convert';

import 'mantra.dart';

final class IosCartProduct {
  const IosCartProduct({
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
}

List<IosCartProduct> buildIosCartProducts(Iterable<Mantra> items) {
  final products = <String, IosCartProduct>{};
  for (final mantra in items) {
    final internalId = mantra.internalProductId.trim();
    final storeId = mantra.storeProductIdIos?.trim() ?? '';
    if (internalId.isEmpty || storeId.isEmpty) {
      throw const FormatException('An iOS store product mapping is missing');
    }
    final quantity = mantra.cartQuantity < 1 ? 1 : mantra.cartQuantity;
    final existing = products[storeId];
    if (existing != null) {
      if (existing.internalProductId != internalId) {
        throw const FormatException(
          'An iOS store product maps to multiple internal products',
        );
      }
      products[storeId] = IosCartProduct(
        internalProductId: internalId,
        productName: existing.productName,
        storeProductId: storeId,
        quantity: existing.quantity + quantity,
      );
      continue;
    }
    products[storeId] = IosCartProduct(
      internalProductId: internalId,
      productName: mantra.name.trim().isEmpty ? internalId : mantra.name,
      storeProductId: storeId,
      quantity: quantity,
    );
  }
  if (products.isEmpty) throw const FormatException('The iOS cart is empty');
  return products.values.toList(growable: false);
}

Map<String, dynamic> buildIosPreparePayload({
  required String currency,
  required Iterable<IosCartProduct> products,
}) => {
  'platform': 'ios',
  'currency': currency.trim().toLowerCase(),
  'products': products.map((item) => item.toPrepareJson()).toList(),
};

Map<String, dynamic> buildIosVerifyPayload({
  required String orderId,
  required String transactionId,
  required String storeProductId,
}) => {
  'orderId': orderId,
  'platform': 'ios',
  'transactionId': transactionId,
  'storeProductId': storeProductId,
};

bool isCanonicalUuid(String value) => RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
).hasMatch(value.trim());

/// StoreKit serializes UUID values using `UUID.uuidString` (normally upper
/// case), while the backend may serialize the same UUID in lower case.
String? normalizeCanonicalUuid(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || !isCanonicalUuid(trimmed)) return null;
  return trimmed.toLowerCase();
}

bool appAccountTokensMatch(String? expected, String? returned) {
  final normalizedExpected = normalizeCanonicalUuid(expected);
  final normalizedReturned = normalizeCanonicalUuid(returned);
  return normalizedExpected != null &&
      normalizedReturned != null &&
      normalizedExpected == normalizedReturned;
}

final class IosPreparedStoreProduct {
  const IosPreparedStoreProduct({
    required this.storeProductId,
    this.internalProductId,
    this.quantity = 1,
  });

  final String storeProductId;
  final String? internalProductId;
  final int quantity;

  factory IosPreparedStoreProduct.fromJson(Map<String, dynamic> json) {
    final rawQuantity = json['quantity'];
    return IosPreparedStoreProduct(
      storeProductId:
          (json['storeProductId'] ?? json['store_product_id'])
              ?.toString()
              .trim() ??
          '',
      internalProductId:
          (json['internalProductId'] ??
                  json['internal_product_id'] ??
                  json['productId'])
              ?.toString()
              .trim(),
      quantity: rawQuantity is int
          ? rawQuantity
          : int.tryParse(rawQuantity?.toString() ?? '') ?? 1,
    );
  }

  Map<String, dynamic> toJson() => {
    'storeProductId': storeProductId,
    if (internalProductId != null) 'internalProductId': internalProductId,
    'quantity': quantity,
  };
}

final class IosPreparedPurchase {
  const IosPreparedPurchase({
    required this.orderId,
    required this.linkToken,
    required this.storeProducts,
  });

  final String orderId;
  final String linkToken;
  final List<IosPreparedStoreProduct> storeProducts;

  factory IosPreparedPurchase.fromJson(Map<String, dynamic> body) {
    final nested = body['data'];
    final data = nested is Map
        ? Map<String, dynamic>.from(nested)
        : Map<String, dynamic>.from(body);
    final rawProducts = data['storeProducts'];
    final result = IosPreparedPurchase(
      orderId: (data['orderId'] ?? data['order_id'])?.toString().trim() ?? '',
      linkToken:
          (data['linkToken'] ?? data['link_token'])?.toString().trim() ?? '',
      storeProducts: rawProducts is List
          ? rawProducts
                .whereType<Map>()
                .map(
                  (item) => IosPreparedStoreProduct.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const [],
    );
    if (result.orderId.isEmpty ||
        result.linkToken.isEmpty ||
        result.storeProducts.isEmpty ||
        result.storeProducts.any(
          (item) => item.storeProductId.isEmpty || item.quantity < 1,
        )) {
      throw const FormatException('Invalid iOS prepare-purchase response');
    }
    return result;
  }
}

void validateIosPreparedProducts({
  required Iterable<IosCartProduct> cart,
  required Iterable<IosPreparedStoreProduct> prepared,
}) {
  final cartList = cart.toList(growable: false);
  final preparedList = prepared.toList(growable: false);
  final expected = {
    for (final item in cartList) item.storeProductId: item.quantity,
  };
  final actual = <String, int>{};
  for (final item in preparedList) {
    if (actual.containsKey(item.storeProductId)) {
      throw const FormatException(
        'Backend returned duplicate iOS store product rows',
      );
    }
    actual[item.storeProductId] = item.quantity;
  }
  if (expected.length != cartList.length ||
      actual.length != preparedList.length ||
      expected.length != actual.length ||
      expected.entries.any((item) => actual[item.key] != item.value)) {
    throw const FormatException(
      'Backend iOS store products do not match the requested cart',
    );
  }
}

List<IosPurchaseUnit> expandIosPreparedUnits({
  required Iterable<IosPreparedStoreProduct> prepared,
  required Iterable<IosCartProduct> cart,
}) {
  final internalIds = {
    for (final item in cart) item.storeProductId: item.internalProductId,
  };
  return prepared
      .expand(
        (item) => List.generate(
          item.quantity,
          (_) => IosPurchaseUnit(
            storeProductId: item.storeProductId,
            internalProductId:
                item.internalProductId ?? internalIds[item.storeProductId],
          ),
          growable: false,
        ),
      )
      .toList(growable: false);
}

final class IosPurchaseUnit {
  const IosPurchaseUnit({
    required this.storeProductId,
    this.internalProductId,
    this.transactionId,
    this.backendAccepted = false,
    this.storeKitCompleted = false,
  });

  final String storeProductId;
  final String? internalProductId;
  final String? transactionId;
  final bool backendAccepted;
  final bool storeKitCompleted;

  IosPurchaseUnit copyWith({
    String? transactionId,
    bool? backendAccepted,
    bool? storeKitCompleted,
  }) => IosPurchaseUnit(
    storeProductId: storeProductId,
    internalProductId: internalProductId,
    transactionId: transactionId ?? this.transactionId,
    backendAccepted: backendAccepted ?? this.backendAccepted,
    storeKitCompleted: storeKitCompleted ?? this.storeKitCompleted,
  );

  Map<String, dynamic> toJson() => {
    'storeProductId': storeProductId,
    if (internalProductId != null) 'internalProductId': internalProductId,
    if (transactionId != null) 'transactionId': transactionId,
    'backendAccepted': backendAccepted,
    'storeKitCompleted': storeKitCompleted,
  };

  factory IosPurchaseUnit.fromJson(Map<String, dynamic> json) =>
      IosPurchaseUnit(
        storeProductId: json['storeProductId']?.toString() ?? '',
        internalProductId: json['internalProductId']?.toString(),
        transactionId: json['transactionId']?.toString(),
        backendAccepted: json['backendAccepted'] == true,
        storeKitCompleted: json['storeKitCompleted'] == true,
      );
}

final class IosPurchaseContext {
  const IosPurchaseContext({
    required this.orderId,
    required this.linkToken,
    required this.units,
    required this.currentIndex,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
  });

  final String orderId;
  final String linkToken;
  final List<IosPurchaseUnit> units;
  final int currentIndex;
  final String state;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get paid => state == 'paid';
  bool get hasUnfinishedWork =>
      !paid ||
      units.any((item) => item.backendAccepted && !item.storeKitCompleted);
  Set<String> get storeProductIds =>
      units.map((item) => item.storeProductId).toSet();
  Set<String> get acceptedStoreProductIds => units
      .where((item) => item.backendAccepted)
      .map((item) => item.storeProductId)
      .toSet();

  Map<String, int> get acceptedQuantityByStoreProductId {
    final result = <String, int>{};
    for (final unit in units.where((item) => item.backendAccepted)) {
      result.update(
        unit.storeProductId,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
    return result;
  }

  IosPurchaseContext copyWith({
    List<IosPurchaseUnit>? units,
    int? currentIndex,
    String? state,
    DateTime? updatedAt,
  }) => IosPurchaseContext(
    orderId: orderId,
    linkToken: linkToken,
    units: units ?? this.units,
    currentIndex: currentIndex ?? this.currentIndex,
    state: state ?? this.state,
    createdAt: createdAt,
    updatedAt: updatedAt ?? DateTime.now().toUtc(),
  );

  IosPurchaseContext recordTransaction({
    required int index,
    required String transactionId,
  }) {
    final updated = List<IosPurchaseUnit>.from(units);
    updated[index] = updated[index].copyWith(transactionId: transactionId);
    return copyWith(units: updated, currentIndex: index, state: 'purchased');
  }

  IosPurchaseContext acceptTransaction({
    required int index,
    required String backendStatus,
  }) {
    final updated = List<IosPurchaseUnit>.from(units);
    updated[index] = updated[index].copyWith(backendAccepted: true);
    return copyWith(
      units: updated,
      currentIndex: index + 1,
      state: backendStatus,
    );
  }

  IosPurchaseContext completeTransaction(int index) {
    final updated = List<IosPurchaseUnit>.from(units);
    updated[index] = updated[index].copyWith(storeKitCompleted: true);
    return copyWith(units: updated);
  }

  IosPurchaseContext acceptPaidOrder() => copyWith(
    units: units
        .map((item) => item.copyWith(backendAccepted: true))
        .toList(growable: false),
    currentIndex: units.length,
    state: 'paid',
  );

  Map<String, dynamic> toJson({bool includeLinkToken = true}) => {
    'orderId': orderId,
    if (includeLinkToken) 'linkToken': linkToken,
    'units': units.map((item) => item.toJson()).toList(),
    'currentIndex': currentIndex,
    'state': state,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  String encodeWithoutToken() => jsonEncode(toJson(includeLinkToken: false));

  factory IosPurchaseContext.fromJson(
    Map<String, dynamic> json, {
    required String linkToken,
  }) => IosPurchaseContext(
    orderId: json['orderId']?.toString() ?? '',
    linkToken: linkToken,
    units: (json['units'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) => IosPurchaseUnit.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false),
    currentIndex: int.tryParse(json['currentIndex']?.toString() ?? '') ?? 0,
    state: json['state']?.toString() ?? 'prepared',
    createdAt:
        DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
        DateTime.now().toUtc(),
    updatedAt:
        DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
        DateTime.now().toUtc(),
  );
}

final class IosPurchaseVerification {
  const IosPurchaseVerification({required this.status});
  final String status;
  bool get accepted => status == 'partially_paid' || status == 'paid';
  bool get paid => status == 'paid';

  factory IosPurchaseVerification.fromJson(Map<String, dynamic> body) {
    final nested = body['data'];
    final data = nested is Map ? Map<String, dynamic>.from(nested) : body;
    final order = data['order'] is Map
        ? Map<String, dynamic>.from(data['order'] as Map)
        : const <String, dynamic>{};
    return IosPurchaseVerification(
      status:
          (data['status'] ??
                  data['paymentStatus'] ??
                  data['payment_status'] ??
                  order['status'] ??
                  '')
              .toString()
              .trim()
              .toLowerCase(),
    );
  }
}

bool iosOrderConflictsWithCart(
  IosPurchaseContext context,
  Iterable<IosCartProduct> visibleProducts,
) {
  final visible = {
    for (final item in visibleProducts) item.storeProductId: item.quantity,
  };
  final remaining = <String, int>{};
  for (final unit in context.units.where((item) => !item.backendAccepted)) {
    remaining.update(
      unit.storeProductId,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
  }
  return remaining.entries.any((item) => (visible[item.key] ?? 0) < item.value);
}

final class IosTransactionDeduplicator {
  final Set<String> _seen = {};

  bool begin(String transactionId) {
    final id = transactionId.trim();
    return id.isNotEmpty && _seen.add(id);
  }
}

import 'dart:async';

import 'package:flutter/services.dart';

import 'play_billing_diagnostics.dart';

final class PlayProductPrice {
  const PlayProductPrice({
    required this.productId,
    required this.formattedPrice,
    required this.priceAmountMicros,
    required this.currencyCode,
  });

  final String productId;
  final String formattedPrice;
  final int priceAmountMicros;
  final String currencyCode;

  factory PlayProductPrice.fromMap(Map<Object?, Object?> map) {
    return PlayProductPrice(
      productId: map['productId']! as String,
      formattedPrice: map['formattedPrice']! as String,
      priceAmountMicros: map['priceAmountMicros']! as int,
      currencyCode: map['priceCurrencyCode']! as String,
    );
  }
}

final class PlayPurchase {
  const PlayPurchase({
    required this.purchaseToken,
    required this.products,
    required this.purchaseState,
    required this.quantity,
    required this.isAcknowledged,
    this.obfuscatedAccountId,
  });

  final String purchaseToken;
  final List<String> products;
  final int purchaseState;
  final int quantity;
  final bool isAcknowledged;
  final String? obfuscatedAccountId;

  bool get isPurchased => purchaseState == 1;
  bool get isPending => purchaseState == 2;

  factory PlayPurchase.fromMap(Map<Object?, Object?> map) => PlayPurchase(
    purchaseToken: map['purchaseToken']?.toString() ?? '',
    products: (map['products'] as List? ?? const [])
        .map((item) => item.toString())
        .toList(growable: false),
    purchaseState: map['purchaseState'] as int? ?? 0,
    quantity: map['quantity'] as int? ?? 1,
    isAcknowledged: map['isAcknowledged'] as bool? ?? false,
    obfuscatedAccountId: map['obfuscatedAccountId']?.toString(),
  );
}

final class PlayPurchaseUpdate {
  const PlayPurchaseUpdate({
    required this.responseCode,
    required this.purchases,
  });

  final int responseCode;
  final List<PlayPurchase> purchases;
  bool get userCancelled => responseCode == 1;

  factory PlayPurchaseUpdate.fromMap(Map<Object?, Object?> map) {
    return PlayPurchaseUpdate(
      responseCode: map['responseCode'] as int? ?? -1,
      purchases: (map['purchases'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => PlayPurchase.fromMap(Map<Object?, Object?>.from(item)))
          .toList(growable: false),
    );
  }
}

final class PlayConsumeResult {
  const PlayConsumeResult({required this.responseCode, this.safeDebugMessage});

  final int responseCode;
  final String? safeDebugMessage;
  bool get completed => responseCode == 0 || responseCode == 8;
  bool get alreadyConsumed => responseCode == 8;
}

/// Android-only platform boundary. Backend verification and consumption stay in Dart/backend.
final class PlayBillingService {
  PlayBillingService._();

  static const _methods = MethodChannel('com.idsai.mantrasutra/play_billing');
  static const _events = EventChannel(
    'com.idsai.mantrasutra/play_billing_events',
  );

  static final Stream<PlayPurchaseUpdate> purchaseUpdates = _events
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .cast<Map>()
      .map(
        (event) =>
            PlayPurchaseUpdate.fromMap(Map<Object?, Object?>.from(event)),
      )
      .asBroadcastStream();

  static Future<void> initialize() async {
    await _methods.invokeMethod<bool>('initialize');
  }

  static Future<Map<String, PlayProductPrice>> queryProducts(
    Iterable<String> productIds,
  ) async {
    final ids = productIds.toSet().toList(growable: false);
    final raw =
        await _methods.invokeListMethod<Object?>(
          'queryProducts',
          <String, Object?>{'productIds': ids},
        ) ??
        const <Object?>[];
    final products = <String, PlayProductPrice>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<Object?, Object?>.from(item);
      if (map['productId'] is! String ||
          map['formattedPrice'] is! String ||
          map['priceAmountMicros'] is! int ||
          map['priceCurrencyCode'] is! String) {
        continue;
      }
      final product = PlayProductPrice.fromMap(map);
      products[product.productId] = product;
    }
    return products;
  }

  static Future<Map<Object?, Object?>> launchMultiProductPurchase({
    required Iterable<String> productIds,
    required String obfuscatedAccountId,
  }) async {
    final ids = productIds.toList(growable: false);
    if (ids.isEmpty || ids.any((id) => id.trim().isEmpty)) {
      throw ArgumentError.value(ids, 'productIds', 'must be non-empty');
    }
    if (ids.toSet().length != ids.length) {
      throw ArgumentError.value(ids, 'productIds', 'must be unique');
    }
    final response = await _methods.invokeMapMethod<Object?, Object?>(
      'launchMultiProductPurchase',
      <String, Object?>{
        'productIds': ids,
        'obfuscatedAccountId': obfuscatedAccountId,
      },
    );
    return response ?? const <Object?, Object?>{};
  }

  static Future<List<PlayPurchase>> queryOutstandingPurchases() async {
    final raw =
        await _methods.invokeListMethod<Object?>('queryOutstandingPurchases') ??
        const <Object?>[];
    return raw
        .whereType<Map>()
        .map((item) => PlayPurchase.fromMap(Map<Object?, Object?>.from(item)))
        .toList(growable: false);
  }

  static Future<PlayConsumeResult> consumePurchase(
    String purchaseToken, {
    String? storeProductId,
  }) async {
    try {
      final response = await _methods.invokeMapMethod<Object?, Object?>(
        'consumePurchase',
        {'purchaseToken': purchaseToken},
      );
      final result = PlayConsumeResult(
        responseCode: response?['responseCode'] as int? ?? -1,
        safeDebugMessage: response?['debugMessage'] == null
            ? null
            : sanitizePlayBillingDiagnostic(response?['debugMessage']),
      );
      return result;
    } on PlatformException {
      rethrow;
    }
  }

  static void debug(String message) {}
}

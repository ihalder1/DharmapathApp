import 'package:flutter/foundation.dart';

/// Highest unit count currently represented by backend-selected aggregate
/// StoreKit products (`multi_02` ... `multi_21`).
const int iosMaxAggregateCartUnits = 21;

bool isAndroidPlayBillingPlatform({TargetPlatform? platform, bool? isWeb}) {
  return !(isWeb ?? kIsWeb) &&
      (platform ?? defaultTargetPlatform) == TargetPlatform.android;
}

bool isIosStoreKitPlatform({TargetPlatform? platform, bool? isWeb}) {
  return !(isWeb ?? kIsWeb) &&
      (platform ?? defaultTargetPlatform) == TargetPlatform.iOS;
}

bool supportsMultipleCartQuantity({TargetPlatform? platform, bool? isWeb}) =>
    !isAndroidPlayBillingPlatform(platform: platform, isWeb: isWeb);

int maxCartTotalQuantity({
  required int existingDefault,
  TargetPlatform? platform,
  bool? isWeb,
}) => isIosStoreKitPlatform(platform: platform, isWeb: isWeb)
    ? iosMaxAggregateCartUnits
    : existingDefault;

int normalizedCartQuantity(
  int quantity, {
  TargetPlatform? platform,
  bool? isWeb,
}) {
  if (!supportsMultipleCartQuantity(platform: platform, isWeb: isWeb)) return 1;
  return quantity < 1 ? 1 : quantity;
}

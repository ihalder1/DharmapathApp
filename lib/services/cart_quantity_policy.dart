import 'package:flutter/foundation.dart';

bool isAndroidPlayBillingPlatform({TargetPlatform? platform, bool? isWeb}) {
  return !(isWeb ?? kIsWeb) &&
      (platform ?? defaultTargetPlatform) == TargetPlatform.android;
}

bool supportsMultipleCartQuantity({TargetPlatform? platform, bool? isWeb}) =>
    !isAndroidPlayBillingPlatform(platform: platform, isWeb: isWeb);

int normalizedCartQuantity(
  int quantity, {
  TargetPlatform? platform,
  bool? isWeb,
}) {
  if (!supportsMultipleCartQuantity(platform: platform, isWeb: isWeb)) return 1;
  return quantity < 1 ? 1 : quantity;
}

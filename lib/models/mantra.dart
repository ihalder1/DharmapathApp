import '../services/location_pricing_service.dart';

class Mantra {
  final String name;
  final String mantraFile;
  final String icon;
  // final int playtime; // in seconds - COMMENTED OUT
  final double price;
  final String currencyCode;
  final bool isInCart;
  final bool isBought; // whether user has purchased this mantra
  /// Licenses owned for this song (from purchase API `available_count`).
  final int purchasedCount;

  Mantra({
    required this.name,
    required this.mantraFile,
    required this.icon,
    // required this.playtime, // COMMENTED OUT
    required this.price,
    this.currencyCode = 'INR',
    this.isInCart = false,
    this.isBought = false,
    this.purchasedCount = 0,
  });

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  factory Mantra.fromJson(
    Map<String, dynamic> json, {
    PricingRegion? region,
  }) {
    final effectiveRegion = region ?? LocationPricingService.cachedRegion;
    final hasRegionalPrices = ['price_in', 'price_sa', 'price_other'].any((k) {
      final v = json[k];
      return v != null && v.toString().trim().isNotEmpty;
    });

    late final double price;
    late final String currencyCode;
    if (hasRegionalPrices && effectiveRegion != null) {
      final resolved = LocationPricingService.resolveSongPricing(
        json,
        effectiveRegion,
      );
      price = resolved.price;
      currencyCode = resolved.currencyCode;
    } else {
      price = _toDouble(json['price']);
      currencyCode = (json['currency_code'] ?? 'INR').toString();
    }
    return Mantra(
      name: json['name'] ?? '',
      mantraFile: json['mantra_file'] ?? '',
      icon: json['icon'] ?? '',
      // playtime: json['playtime'] ?? 0, // COMMENTED OUT
      price: price,
      currencyCode: currencyCode,
      purchasedCount: (json['purchased_count'] is int)
          ? json['purchased_count'] as int
          : int.tryParse(json['purchased_count']?.toString() ?? '') ?? 0,
    );
  }

  // Factory method for API data (song_id instead of mantra_file)
  factory Mantra.fromApiJson(
    Map<String, dynamic> json, {
    PricingRegion? region,
  }) {
    final effectiveRegion = region ?? LocationPricingService.cachedRegion;
    final hasRegionalPrices = ['price_in', 'price_sa', 'price_other'].any((k) {
      final v = json[k];
      return v != null && v.toString().trim().isNotEmpty;
    });
    late final double price;
    late final String currencyCode;
    if (hasRegionalPrices && effectiveRegion != null) {
      final resolved = LocationPricingService.resolveSongPricing(
        json,
        effectiveRegion,
      );
      price = resolved.price;
      currencyCode = resolved.currencyCode;
    } else {
      price = _toDouble(json['price']);
      currencyCode = (json['currency_code'] ?? 'INR').toString();
    }
    return Mantra(
      name: json['name'] ?? '',
      mantraFile: json['song_id'] ?? json['mantra_file'] ?? '', // Support both API and JSON formats
      icon: json['icon'] ?? '',
      // playtime: json['runtime'] ?? json['playtime'] ?? 0, // Support both API and JSON formats - COMMENTED OUT
      price: price,
      currencyCode: currencyCode,
      isBought: json['bought'] == 'Y', // Convert "Y"/"N" to boolean
      purchasedCount: (json['available_count'] is int)
          ? json['available_count'] as int
          : int.tryParse(json['available_count']?.toString() ?? '') ??
              (json['bought'] == 'Y' ? 1 : 0),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'mantra_file': mantraFile,
      'icon': icon,
      // 'playtime': playtime, // COMMENTED OUT
      'price': price,
      'currency_code': currencyCode,
      'purchased_count': purchasedCount,
    };
  }

  Mantra copyWith({
    String? name,
    String? mantraFile,
    String? icon,
    // int? playtime, // COMMENTED OUT
    double? price,
    String? currencyCode,
    bool? isInCart,
    bool? isBought,
    int? purchasedCount,
  }) {
    return Mantra(
      name: name ?? this.name,
      mantraFile: mantraFile ?? this.mantraFile,
      icon: icon ?? this.icon,
      // playtime: playtime ?? this.playtime, // COMMENTED OUT
      price: price ?? this.price,
      currencyCode: currencyCode ?? this.currencyCode,
      isInCart: isInCart ?? this.isInCart,
      isBought: isBought ?? this.isBought,
      purchasedCount: purchasedCount ?? this.purchasedCount,
    );
  }

  // Helper method to format playtime as MM:SS - COMMENTED OUT
  // String get formattedPlaytime {
  //   final minutes = playtime ~/ 60;
  //   final seconds = playtime % 60;
  //   return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  // }

  // Helper method to format price
  String get formattedPrice {
    if (currencyCode.toUpperCase() == 'USD') {
      return '${currencySymbolFor(currencyCode)}${price.toStringAsFixed(2)}';
    }
    final whole = price % 1 == 0;
    return '${currencySymbolFor(currencyCode)}${whole ? price.toInt() : price.toStringAsFixed(2)}';
  }

  static String currencySymbolFor(String code) {
    switch (code.toUpperCase()) {
      case 'USD':
        return r'$';
      case 'INR':
      default:
        return '₹';
    }
  }
}

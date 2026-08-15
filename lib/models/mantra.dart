import '../services/location_pricing_service.dart';

class Mantra {
  final String songId;
  final String name;
  final String mantraFile;
  final String icon;
  final String? storeProductIdAndroid;
  final String? localAudioPath;
  final bool dynamicAssetsPending;
  // final int playtime; // in seconds - COMMENTED OUT
  final double price;
  final String currencyCode;
  final bool isInCart;
  final bool isBought; // whether user has purchased this mantra
  /// Licenses owned for this song (from purchase API `available_count`).
  final int purchasedCount;

  /// How many units of this mantra are in the cart (≥ 1 when [isInCart]).
  final int cartQuantity;

  Mantra({
    this.songId = '',
    required this.name,
    required this.mantraFile,
    required this.icon,
    this.storeProductIdAndroid,
    this.localAudioPath,
    this.dynamicAssetsPending = false,
    // required this.playtime, // COMMENTED OUT
    required this.price,
    this.currencyCode = 'INR',
    this.isInCart = false,
    this.isBought = false,
    this.purchasedCount = 0,
    this.cartQuantity = 1,
  });

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  factory Mantra.fromJson(Map<String, dynamic> json, {PricingRegion? region}) {
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
      songId:
          _optionalString(json['song_id']) ??
          _songIdFromFile(json['mantra_file']?.toString() ?? ''),
      name: json['name'] ?? '',
      mantraFile: json['mantra_file'] ?? '',
      icon: json['icon'] ?? '',
      storeProductIdAndroid: _optionalString(json['store_product_id_android']),
      localAudioPath: _optionalString(json['local_audio_path']),
      dynamicAssetsPending: json['dynamic_assets_pending'] == true,
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
      songId: _optionalString(json['id'] ?? json['song_id']) ?? '',
      name: json['name'] ?? '',
      mantraFile:
          json['song_id'] ??
          json['mantra_file'] ??
          '', // Support both API and JSON formats
      icon: json['icon'] ?? '',
      storeProductIdAndroid: _optionalString(json['store_product_id_android']),
      localAudioPath: _optionalString(json['local_audio_path']),
      dynamicAssetsPending: json['dynamic_assets_pending'] == true,
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
      'song_id': songId,
      'mantra_file': mantraFile,
      'icon': icon,
      if (storeProductIdAndroid != null)
        'store_product_id_android': storeProductIdAndroid,
      if (localAudioPath != null) 'local_audio_path': localAudioPath,
      'dynamic_assets_pending': dynamicAssetsPending,
      // 'playtime': playtime, // COMMENTED OUT
      'price': price,
      'currency_code': currencyCode,
      'purchased_count': purchasedCount,
    };
  }

  Mantra copyWith({
    String? songId,
    String? name,
    String? mantraFile,
    String? icon,
    String? storeProductIdAndroid,
    String? localAudioPath,
    bool clearLocalAudioPath = false,
    bool? dynamicAssetsPending,
    // int? playtime, // COMMENTED OUT
    double? price,
    String? currencyCode,
    bool? isInCart,
    bool? isBought,
    int? purchasedCount,
    int? cartQuantity,
  }) {
    return Mantra(
      songId: songId ?? this.songId,
      name: name ?? this.name,
      mantraFile: mantraFile ?? this.mantraFile,
      icon: icon ?? this.icon,
      storeProductIdAndroid:
          storeProductIdAndroid ?? this.storeProductIdAndroid,
      localAudioPath: clearLocalAudioPath
          ? null
          : (localAudioPath ?? this.localAudioPath),
      dynamicAssetsPending: dynamicAssetsPending ?? this.dynamicAssetsPending,
      // playtime: playtime ?? this.playtime, // COMMENTED OUT
      price: price ?? this.price,
      currencyCode: currencyCode ?? this.currencyCode,
      isInCart: isInCart ?? this.isInCart,
      isBought: isBought ?? this.isBought,
      purchasedCount: purchasedCount ?? this.purchasedCount,
      cartQuantity: cartQuantity ?? this.cartQuantity,
    );
  }

  double get lineTotal => price * cartQuantity;

  String formattedLineTotal() => formatMoney(lineTotal, currencyCode);

  // Helper method to format price
  String get formattedPrice => formatMoney(price, currencyCode);

  /// Backend song/product ID (for example `F-AARATI-001`).
  String get internalProductId {
    if (songId.trim().isNotEmpty) return songId.trim();
    final value = mantraFile.trim();
    final slash = value.lastIndexOf(RegExp(r'[/\\]'));
    final fileName = slash >= 0 ? value.substring(slash + 1) : value;
    return fileName.toLowerCase().endsWith('.mp3')
        ? fileName.substring(0, fileName.length - 4)
        : fileName;
  }

  /// e.g. `USD 2.00`, `INR 99`
  static String formatMoney(double amount, String currencyCode) {
    final code = currencyCode.toUpperCase();
    if (code == 'USD') {
      return 'USD ${amount.toStringAsFixed(2)}';
    }
    final whole = amount % 1 == 0;
    final value = whole ? amount.toInt().toString() : amount.toStringAsFixed(2);
    return 'INR $value';
  }

  static String currencySymbolFor(String code) {
    switch (code.toUpperCase()) {
      case 'USD':
        return 'USD';
      case 'INR':
      default:
        return 'INR';
    }
  }

  static String? _optionalString(dynamic value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static String _songIdFromFile(String value) {
    final slash = value.lastIndexOf(RegExp(r'[/\\]'));
    final fileName = slash >= 0 ? value.substring(slash + 1) : value;
    return fileName.toLowerCase().endsWith('.mp3')
        ? fileName.substring(0, fileName.length - 4)
        : fileName;
  }
}

class Mantra {
  final String name;
  final String mantraFile;
  final String icon;
  // final int playtime; // in seconds - COMMENTED OUT
  final double price;
  final String currencyCode;
  final bool isInCart;
  final bool isBought; // whether user has purchased this mantra

  Mantra({
    required this.name,
    required this.mantraFile,
    required this.icon,
    // required this.playtime, // COMMENTED OUT
    required this.price,
    this.currencyCode = 'INR',
    this.isInCart = false,
    this.isBought = false,
  });

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  factory Mantra.fromJson(Map<String, dynamic> json) {
    return Mantra(
      name: json['name'] ?? '',
      mantraFile: json['mantra_file'] ?? '',
      icon: json['icon'] ?? '',
      // playtime: json['playtime'] ?? 0, // COMMENTED OUT
      price: _toDouble(json['price']),
      currencyCode: (json['currency_code'] ?? 'INR').toString(),
    );
  }

  // Factory method for API data (song_id instead of mantra_file)
  factory Mantra.fromApiJson(Map<String, dynamic> json) {
    return Mantra(
      name: json['name'] ?? '',
      mantraFile: json['song_id'] ?? json['mantra_file'] ?? '', // Support both API and JSON formats
      icon: json['icon'] ?? '',
      // playtime: json['runtime'] ?? json['playtime'] ?? 0, // Support both API and JSON formats - COMMENTED OUT
      price: _toDouble(json['price']),
      currencyCode: (json['currency_code'] ?? 'INR').toString(),
      isBought: json['bought'] == 'Y', // Convert "Y"/"N" to boolean
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

import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

/// Regional pricing tier for song list / checkout.
enum PricingRegion {
  /// India — `price_in`, INR, UPI available.
  india,

  /// Bangladesh & Nepal — `price_sa`, USD.
  southAsia,

  /// All other countries — `price_other`, USD.
  other,
}

class LocationPricingService {
  static const String _geoLookupUrl = 'https://ipapi.co/json/';

  static PricingRegion? _cachedRegion;

  /// Last resolved region (after [getPricingRegion]).
  static PricingRegion? get cachedRegion => _cachedRegion;

  static Future<PricingRegion> getPricingRegion() async {
    if (_cachedRegion != null) {
      return _cachedRegion!;
    }
    final countryCode = await _fetchCountryCode();
    _cachedRegion = _regionFromCountryCode(countryCode);
    return _cachedRegion!;
  }

  static Future<bool> isUserInIndia() async {
    final region = await getPricingRegion();
    return region == PricingRegion.india;
  }

  static String currencyCodeForRegion(PricingRegion region) {
    return region == PricingRegion.india ? 'INR' : 'USD';
  }

  /// Tax pricing guidance shown alongside the mantra catalog.
  static String taxPriceLabel(PricingRegion region) {
    return switch (region) {
      PricingRegion.india => '95 INR + GST',
      PricingRegion.southAsia => '1 USD + VAT/GST',
      PricingRegion.other => '2 USD + VAT/GST',
    };
  }

  static double parsePrice(dynamic value) {
    if (value is num) return value.toDouble();
    final s = value?.toString().trim() ?? '';
    if (s.isEmpty) return 0;
    return double.tryParse(s) ?? 0;
  }

  /// Picks `price_in` / `price_sa` / `price_other` for [region]; falls back across fields.
  static ({double price, String currencyCode}) resolveSongPricing(
    Map<String, dynamic> song,
    PricingRegion region,
  ) {
    String? pick(PricingRegion r) {
      switch (r) {
        case PricingRegion.india:
          return _nonEmptyPrice(song['price_in']);
        case PricingRegion.southAsia:
          return _nonEmptyPrice(song['price_sa']);
        case PricingRegion.other:
          return _nonEmptyPrice(song['price_other']);
      }
    }

    final raw =
        pick(region) ??
        _nonEmptyPrice(song['price_in']) ??
        _nonEmptyPrice(song['price_sa']) ??
        _nonEmptyPrice(song['price_other']) ??
        _nonEmptyPrice(song['price']);

    return (
      price: parsePrice(raw ?? '0'),
      currencyCode: currencyCodeForRegion(region),
    );
  }

  /// Writes regional price fields and resolved [price] / [currency_code] on [target].
  static void applyApiPricingToMetadata(
    Map<String, dynamic> target,
    Map<String, dynamic> apiSong,
    PricingRegion region,
  ) {
    for (final key in ['price_in', 'price_sa', 'price_other']) {
      final v = apiSong[key];
      if (v != null) {
        target[key] = v.toString();
      }
    }
    final resolved = resolveSongPricing(apiSong, region);
    target['price'] = resolved.price;
    target['currency_code'] = resolved.currencyCode;
  }

  static PricingRegion _regionFromCountryCode(String? code) {
    switch (code?.toUpperCase()) {
      case 'IN':
        return PricingRegion.india;
      case 'BD':
      case 'NP':
        return PricingRegion.southAsia;
      default:
        return PricingRegion.other;
    }
  }

  static Future<String?> _fetchCountryCode() async {
    try {
      final response = await http
          .get(Uri.parse(_geoLookupUrl))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final Map<String, dynamic> data =
            json.decode(response.body) as Map<String, dynamic>;
        final countryCode = (data['country_code'] ?? '')
            .toString()
            .toUpperCase()
            .trim();
        if (countryCode.isNotEmpty) {
          return countryCode;
        }
      }
    } catch (_) {
      // Fall through to locale fallback
    }

    return WidgetsBinding.instance.platformDispatcher.locale.countryCode
        ?.toUpperCase();
  }

  static String? _nonEmptyPrice(dynamic value) {
    if (value == null) return null;
    final s = value.toString().trim();
    return s.isEmpty ? null : s;
  }
}

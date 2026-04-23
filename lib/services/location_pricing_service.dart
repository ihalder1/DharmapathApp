import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

class LocationPricingService {
  static const String _geoLookupUrl = 'https://ipapi.co/json/';

  static bool? _cachedIsInIndia;

  static Future<bool> isUserInIndia() async {
    if (_cachedIsInIndia != null) {
      return _cachedIsInIndia!;
    }

    try {
      final response = await http.get(Uri.parse(_geoLookupUrl)).timeout(
        const Duration(seconds: 5),
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> data =
            json.decode(response.body) as Map<String, dynamic>;
        final countryCode = (data['country_code'] ?? '')
            .toString()
            .toUpperCase()
            .trim();
        if (countryCode.isNotEmpty) {
          _cachedIsInIndia = countryCode == 'IN';
          return _cachedIsInIndia!;
        }
      }
    } catch (_) {
      // Fall through to locale fallback
    }

    final localeCountryCode =
        WidgetsBinding.instance.platformDispatcher.locale.countryCode
            ?.toUpperCase();
    _cachedIsInIndia = localeCountryCode == 'IN';
    return _cachedIsInIndia!;
  }

  static String currencyCodeForIndiaFlag(bool isInIndia) {
    return isInIndia ? 'INR' : 'USD';
  }
}

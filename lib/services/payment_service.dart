import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../constants/api_config.dart';
import 'auth_service.dart';
import 'authenticated_http.dart';

class PaymentService {
  // Create Payment Intent
  static Future<Map<String, dynamic>?> createPaymentIntent({
    required int amount,
    required String currency,
    required String productId,
    required String productName,
    required String customerEmail,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('💳 CREATE PAYMENT INTENT API CALL START');
      print('═══════════════════════════════════════════════════════════');
      
      final authService = AuthService();
      final token = authService.accessToken;
      if (token == null) {
        print('❌ ERROR: No authentication token found');
        print('═══════════════════════════════════════════════════════════');
        return null;
      }

      final url = '${ApiConfig.paymentBaseUrl}${ApiConfig.createPaymentIntentEndpoint}';
      final headers = ApiConfig.getPaymentHeaders(accessToken: token);
      final requestBody = {
        'amount': amount,
        'currency': currency,
        'productId': productId,
        'productName': productName,
        'customerEmail': customerEmail,
        if (metadata != null) 'metadata': metadata,
      };

      print('📤 REQUEST DETAILS:');
      print('   Method: POST');
      print('   URL: $url');
      print('   Headers: ${json.encode(headers)}');
      print('   Body: ${json.encode(requestBody)}');
      print('   FULL TOKEN: $token');

      final response = await AuthenticatedHttp.paymentPost(
        Uri.parse(url),
        body: json.encode(requestBody),
      );

      print('📥 RESPONSE DETAILS:');
      print('   Status Code: ${response.statusCode}');
      print('   Response Headers: ${response.headers}');
      print('   Response Body: ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = json.decode(response.body);
        print('✅ CREATE PAYMENT INTENT SUCCESS');
        print('   Client Secret: ${responseData['clientSecret']}');
        print('   Payment Intent ID: ${responseData['paymentIntentId']}');
        print('   Status: ${responseData['status']}');
        print('═══════════════════════════════════════════════════════════');
        return responseData;
      } else {
        print('❌ CREATE PAYMENT INTENT FAILED');
        print('   Status: ${response.statusCode}');
        print('   Body: ${response.body}');
        print('═══════════════════════════════════════════════════════════');
        return null;
      }
    } catch (e, stackTrace) {
      print('❌ CREATE PAYMENT INTENT ERROR:');
      print('   Error: $e');
      print('   StackTrace: $stackTrace');
      print('═══════════════════════════════════════════════════════════');
      debugPrint('Error creating payment intent: $e');
      return null;
    }
  }

  // Confirm Payment (Backend Verification)
  static Future<bool> confirmPayment({
    required String paymentIntentId,
  }) async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('✅ CONFIRM PAYMENT API CALL START');
      print('═══════════════════════════════════════════════════════════');
      
      final authService = AuthService();
      final token = authService.accessToken;
      if (token == null) {
        print('❌ ERROR: No authentication token found');
        print('═══════════════════════════════════════════════════════════');
        return false;
      }

      final url = '${ApiConfig.paymentBaseUrl}${ApiConfig.confirmPaymentEndpoint}';
      final headers = ApiConfig.getPaymentHeaders(accessToken: token);
      final requestBody = {
        'paymentIntentId': paymentIntentId,
      };

      print('📤 REQUEST DETAILS:');
      print('   Method: POST');
      print('   URL: $url');
      print('   Headers: ${json.encode(headers)}');
      print('   Body: ${json.encode(requestBody)}');
      print('   FULL TOKEN: $token');

      final response = await AuthenticatedHttp.paymentPost(
        Uri.parse(url),
        body: json.encode(requestBody),
      );

      print('📥 RESPONSE DETAILS:');
      print('   Status Code: ${response.statusCode}');
      print('   Response Headers: ${response.headers}');
      print('   Response Body: ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        print('✅ CONFIRM PAYMENT SUCCESS');
        print('═══════════════════════════════════════════════════════════');
        return true;
      } else {
        print('❌ CONFIRM PAYMENT FAILED');
        print('   Status: ${response.statusCode}');
        print('   Body: ${response.body}');
        print('═══════════════════════════════════════════════════════════');
        return false;
      }
    } catch (e, stackTrace) {
      print('❌ CONFIRM PAYMENT ERROR:');
      print('   Error: $e');
      print('   StackTrace: $stackTrace');
      print('═══════════════════════════════════════════════════════════');
      debugPrint('Error confirming payment: $e');
      return false;
    }
  }

  // Get Payment Status
  static Future<Map<String, dynamic>?> getPaymentStatus({
    required String paymentIntentId,
  }) async {
    try {
      print('═══════════════════════════════════════════════════════════');
      print('📊 GET PAYMENT STATUS API CALL START');
      print('═══════════════════════════════════════════════════════════');
      
      final authService = AuthService();
      final token = authService.accessToken;
      if (token == null) {
        print('❌ ERROR: No authentication token found');
        print('═══════════════════════════════════════════════════════════');
        return null;
      }

      final url = '${ApiConfig.paymentBaseUrl}${ApiConfig.getPaymentStatusEndpoint}/$paymentIntentId';
      final headers = ApiConfig.getPaymentHeaders(accessToken: token);

      print('📤 REQUEST DETAILS:');
      print('   Method: GET');
      print('   URL: $url');
      print('   Headers: ${json.encode(headers)}');
      print('   FULL TOKEN: $token');

      final response =
          await AuthenticatedHttp.paymentGet(Uri.parse(url));

      print('📥 RESPONSE DETAILS:');
      print('   Status Code: ${response.statusCode}');
      print('   Response Headers: ${response.headers}');
      print('   Response Body: ${response.body}');

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        print('✅ GET PAYMENT STATUS SUCCESS');
        print('   Data: ${json.encode(responseData)}');
        print('═══════════════════════════════════════════════════════════');
        return responseData;
      } else {
        print('❌ GET PAYMENT STATUS FAILED');
        print('   Status: ${response.statusCode}');
        print('   Body: ${response.body}');
        print('═══════════════════════════════════════════════════════════');
        return null;
      }
    } catch (e, stackTrace) {
      print('❌ GET PAYMENT STATUS ERROR:');
      print('   Error: $e');
      print('   StackTrace: $stackTrace');
      print('═══════════════════════════════════════════════════════════');
      debugPrint('Error getting payment status: $e');
      return null;
    }
  }
}


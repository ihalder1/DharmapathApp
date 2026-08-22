import 'dart:convert';

import '../constants/api_config.dart';
import '../models/android_purchase.dart';
import '../models/ios_purchase.dart';
import 'authenticated_http.dart';
import 'play_billing_diagnostics.dart';
import 'storekit_diagnostics.dart';

class PaymentService {
  static Future<PreparedPurchase> prepareAndroidPurchase({
    required String currency,
    required List<AndroidCartProduct> products,
    AndroidPaymentDiagnosticCallback? onDiagnostic,
  }) async {
    playBillingLog(
      'operation=prepare platform=android currency=${currency.toLowerCase()} '
      'products=${products.map((item) => {'internalId': item.internalProductId, 'storeId': item.storeProductId, 'quantity': item.quantity}).toList()}',
    );
    final response = await AuthenticatedHttp.paymentPost(
      Uri.parse(
        '${ApiConfig.paymentBaseUrl}${ApiConfig.prepareAndroidPurchaseEndpoint}',
      ),
      body: jsonEncode({
        'platform': 'android',
        'currency': currency.toLowerCase(),
        'products': products.map((item) => item.toPrepareJson()).toList(),
      }),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      final safeError = safeAndroidBillingErrorFromBody(response.body);
      onDiagnostic?.call(
        AndroidPaymentDiagnostic(
          operation: 'prepare',
          stage: 'http_failure',
          httpStatus: response.statusCode,
          backendStatus: safeError.status,
          safeCode: safeError.code,
          safeMessage: safeError.message,
        ),
      );
      playBillingLog(
        'operation=prepare httpStatus=${response.statusCode} '
        '${_safeAndroidBillingError(response.body)}',
      );
      throw AndroidBillingHttpException(
        operation: 'prepare',
        httpStatus: response.statusCode,
        safeCode: safeError.code,
        safeMessage: safeError.message,
      );
    }
    try {
      final body = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      final data = _androidBillingData(body);
      onDiagnostic?.call(
        AndroidPaymentDiagnostic(
          operation: 'prepare',
          stage: 'http_success',
          httpStatus: response.statusCode,
          backendStatus: _safeStatus(data),
        ),
      );
      final prepared = PreparedPurchase.fromJson(body);
      onDiagnostic?.call(
        AndroidPaymentDiagnostic(
          operation: 'prepare',
          stage: 'parsed',
          httpStatus: response.statusCode,
          backendStatus: _safeStatus(data),
          orderId: prepared.orderId,
          storeProductIds: prepared.storeProducts
              .map((item) => item.storeProductId)
              .toList(growable: false),
          linkTokenPresent: prepared.linkToken.isNotEmpty,
        ),
      );
      playBillingLog(
        'operation=prepare httpStatus=${response.statusCode} '
        'bodyShape=${_androidBillingBodyShape(body)} '
        'hasOrderId=${prepared.orderId.isNotEmpty} '
        'hasLinkToken=${prepared.linkToken.isNotEmpty} '
        'storeProductIds=${prepared.storeProducts.map((item) => item.storeProductId).toList()} '
        'backendStatus=${_safeStatus(data)}',
      );
      return prepared;
    } catch (error) {
      onDiagnostic?.call(
        AndroidPaymentDiagnostic(
          operation: 'prepare',
          stage: 'parse_failure',
          httpStatus: response.statusCode,
          errorType: error.runtimeType.toString(),
          safeMessage: sanitizePlayBillingDiagnostic(error),
        ),
      );
      playBillingLog(
        'operation=prepare parseFailure=true httpStatus=${response.statusCode} '
        'exceptionType=${error.runtimeType}',
      );
      rethrow;
    }
  }

  static Future<PurchaseVerification> verifyAndroidPurchase({
    required String orderId,
    required String purchaseToken,
    AndroidPaymentDiagnosticCallback? onDiagnostic,
  }) async {
    playBillingLog('operation=verify order=$orderId request=start');
    final response = await AuthenticatedHttp.paymentPost(
      Uri.parse(
        '${ApiConfig.paymentBaseUrl}${ApiConfig.verifyAndroidPurchaseEndpoint}',
      ),
      body: jsonEncode({
        'orderId': orderId,
        'platform': 'android',
        'purchaseToken': purchaseToken,
      }),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      final safeError = safeAndroidBillingErrorFromBody(response.body);
      onDiagnostic?.call(
        AndroidPaymentDiagnostic(
          operation: 'verify',
          stage: 'http_failure',
          httpStatus: response.statusCode,
          backendStatus: safeError.status,
          safeCode: safeError.code,
          safeMessage: safeError.message,
        ),
      );
      playBillingLog(
        'operation=verify order=$orderId '
        'httpStatus=${response.statusCode} '
        '${_safeAndroidBillingError(response.body)}',
      );
      throw AndroidBillingHttpException(
        operation: 'verify',
        httpStatus: response.statusCode,
        safeCode: safeError.code,
        safeMessage: safeError.message,
      );
    }
    try {
      final body = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      onDiagnostic?.call(
        AndroidPaymentDiagnostic(
          operation: 'verify',
          stage: 'http_success',
          httpStatus: response.statusCode,
        ),
      );
      final verification = PurchaseVerification.fromJson(body);
      onDiagnostic?.call(
        AndroidPaymentDiagnostic(
          operation: 'verify',
          stage: 'parsed',
          httpStatus: response.statusCode,
          backendStatus: verification.status,
          accepted: verification.accepted,
          paid: verification.paid,
        ),
      );
      playBillingLog(
        'operation=verify order=$orderId '
        'httpStatus=${response.statusCode} status=${verification.status} '
        'accepted=${verification.accepted} paid=${verification.paid}',
      );
      return verification;
    } catch (error) {
      onDiagnostic?.call(
        AndroidPaymentDiagnostic(
          operation: 'verify',
          stage: 'parse_failure',
          httpStatus: response.statusCode,
          errorType: error.runtimeType.toString(),
          safeMessage: sanitizePlayBillingDiagnostic(error),
        ),
      );
      playBillingLog(
        'operation=verify order=$orderId '
        'parseFailure=true httpStatus=${response.statusCode} '
        'exceptionType=${error.runtimeType}',
      );
      rethrow;
    }
  }

  static Map<String, dynamic> _androidBillingData(Map<String, dynamic> body) {
    final data = body['data'];
    return data is Map ? Map<String, dynamic>.from(data) : body;
  }

  static String _androidBillingBodyShape(Map<String, dynamic> body) {
    final data = body['data'];
    if (data is Map) return 'object_with_data_object';
    if (data is List) return 'object_with_data_list';
    return 'object';
  }

  static String _safeStatus(Map<String, dynamic> data) =>
      (data['status'] ?? data['paymentStatus'] ?? data['payment_status'] ?? '')
          .toString()
          .trim()
          .toLowerCase();

  static String _safeAndroidBillingError(String responseBody) {
    try {
      final body = Map<String, dynamic>.from(jsonDecode(responseBody) as Map);
      final data = _androidBillingData(body);
      final rawCode = (data['code'] ?? data['errorCode'] ?? data['error_code'])
          ?.toString()
          .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '');
      final code = rawCode?.substring(0, rawCode.length.clamp(0, 64));
      final hasMessage = data['message'] != null || data['error'] is String;
      return 'errorCode=${code == null || code.isEmpty ? 'unknown' : code} '
          'hasMessage=$hasMessage bodyShape=${_androidBillingBodyShape(body)}';
    } catch (_) {
      return 'errorCode=unparseable hasMessage=false bodyShape=unknown';
    }
  }

  static Future<PurchaseVerification> getAndroidPurchaseOrder(
    String orderId, {
    AndroidPaymentDiagnosticCallback? onDiagnostic,
  }) async {
    final response = await AuthenticatedHttp.paymentGet(
      Uri.parse(
        '${ApiConfig.paymentBaseUrl}${ApiConfig.androidPurchaseOrderEndpoint(orderId)}',
      ),
    );
    playBillingLog(
      'order lookup order=$orderId httpStatus=${response.statusCode}',
    );
    if (response.statusCode != 200) {
      final safeError = safeAndroidBillingErrorFromBody(response.body);
      onDiagnostic?.call(
        AndroidPaymentDiagnostic(
          operation: 'order_lookup',
          stage: 'http_failure',
          httpStatus: response.statusCode,
          safeCode: safeError.code,
          safeMessage: safeError.message,
          backendStatus: safeError.status,
        ),
      );
      throw StateError('purchase_order_failed_${response.statusCode}');
    }
    final verification = PurchaseVerification.fromJson(
      Map<String, dynamic>.from(jsonDecode(response.body) as Map),
    );
    onDiagnostic?.call(
      AndroidPaymentDiagnostic(
        operation: 'order_lookup',
        stage: 'parsed',
        httpStatus: response.statusCode,
        backendStatus: verification.status,
        accepted: verification.accepted,
        paid: verification.paid,
      ),
    );
    return verification;
  }

  static Future<PurchaseVerification> restoreAndroidPurchases(
    List<Map<String, String>> purchases,
  ) async {
    final response = await AuthenticatedHttp.paymentPost(
      Uri.parse(
        '${ApiConfig.paymentBaseUrl}${ApiConfig.restoreAndroidPurchasesEndpoint}',
      ),
      body: jsonEncode({'platform': 'android', 'purchases': purchases}),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw StateError('restore_purchase_failed_${response.statusCode}');
    }
    return PurchaseVerification.fromJson(
      Map<String, dynamic>.from(jsonDecode(response.body) as Map),
    );
  }

  static Future<IosPreparedPurchase> prepareIosPurchase({
    required String currency,
    required List<IosCartProduct> products,
    StoreKitDiagnostics? diagnostics,
  }) async {
    diagnostics?.logPrepareRequest(currency: currency, products: products);
    final response = await AuthenticatedHttp.paymentPost(
      Uri.parse(
        '${ApiConfig.paymentBaseUrl}${ApiConfig.prepareAndroidPurchaseEndpoint}',
      ),
      body: jsonEncode(
        buildIosPreparePayload(currency: currency, products: products),
      ),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      diagnostics?.logPrepareResponse(
        httpStatus: response.statusCode,
        orderIdPresent: false,
        linkTokenPresent: false,
      );
      diagnostics?.logError(
        stage: 'prepare_http',
        error: StateError('Prepare Purchase HTTP failure'),
        httpStatus: response.statusCode,
      );
      throw StateError('ios_prepare_purchase_failed_${response.statusCode}');
    }
    final body = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    final nested = body['data'];
    final data = nested is Map ? Map<String, dynamic>.from(nested) : body;
    final rawOrderId = (data['orderId'] ?? data['order_id'])?.toString();
    final rawLinkToken = (data['linkToken'] ?? data['link_token'])?.toString();
    diagnostics?.logPrepareResponse(
      httpStatus: response.statusCode,
      orderIdPresent: rawOrderId?.trim().isNotEmpty == true,
      orderId: rawOrderId,
      linkTokenPresent: rawLinkToken?.trim().isNotEmpty == true,
      linkTokenValid: rawLinkToken == null
          ? false
          : isCanonicalUuid(rawLinkToken),
      storeProducts: data['storeProducts'],
    );
    return IosPreparedPurchase.fromJson(body);
  }

  static Future<IosPurchaseVerification> verifyIosPurchase({
    required String orderId,
    required String transactionId,
    required String storeProductId,
    StoreKitDiagnostics? diagnostics,
  }) async {
    diagnostics?.logVerify(
      event: 'BACKEND_VERIFY_STARTED',
      orderId: orderId,
      storeProductId: storeProductId,
      transactionId: transactionId,
    );
    final response = await AuthenticatedHttp.paymentPost(
      Uri.parse(
        '${ApiConfig.paymentBaseUrl}${ApiConfig.verifyAndroidPurchaseEndpoint}',
      ),
      body: jsonEncode(
        buildIosVerifyPayload(
          orderId: orderId,
          transactionId: transactionId,
          storeProductId: storeProductId,
        ),
      ),
    );
    diagnostics?.logVerifyHttpResponse(
      httpStatus: response.statusCode,
      responseBody: response.body,
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      diagnostics?.logVerify(
        event: 'BACKEND_VERIFY_FAILED',
        orderId: orderId,
        storeProductId: storeProductId,
        transactionId: transactionId,
        httpStatus: response.statusCode,
        backendStatus: 'error',
      );
      diagnostics?.logError(
        stage: 'verify_http',
        error: StateError('Verify Purchase HTTP failure'),
        httpStatus: response.statusCode,
      );
      throw StateError('ios_verify_purchase_failed_${response.statusCode}');
    }
    final verification = IosPurchaseVerification.fromJson(
      Map<String, dynamic>.from(jsonDecode(response.body) as Map),
    );
    diagnostics?.logVerify(
      event: verification.status == 'partially_paid'
          ? 'BACKEND_ACCEPTED_PARTIAL'
          : verification.status == 'paid'
          ? 'BACKEND_ACCEPTED_PAID'
          : 'BACKEND_VERIFY_RESULT',
      orderId: orderId,
      storeProductId: storeProductId,
      transactionId: transactionId,
      httpStatus: response.statusCode,
      backendStatus: verification.status.isEmpty
          ? 'other'
          : verification.status,
    );
    return verification;
  }

  static Future<IosPurchaseVerification> getIosPurchaseOrder(
    String orderId, {
    StoreKitDiagnostics? diagnostics,
  }) async {
    final response = await AuthenticatedHttp.paymentGet(
      Uri.parse(
        '${ApiConfig.paymentBaseUrl}${ApiConfig.androidPurchaseOrderEndpoint(orderId)}',
      ),
    );
    if (response.statusCode != 200) {
      diagnostics?.logError(
        stage: 'order_status_http',
        error: StateError('Order status HTTP failure'),
        httpStatus: response.statusCode,
      );
      throw StateError('ios_purchase_order_failed_${response.statusCode}');
    }
    final verification = IosPurchaseVerification.fromJson(
      Map<String, dynamic>.from(jsonDecode(response.body) as Map),
    );
    diagnostics?.log('RECONCILIATION_ORDER_STATUS', {
      'orderId': StoreKitDiagnostics.redactIdentifier(orderId),
      'httpStatus': response.statusCode,
      'backendStatus': verification.status,
    });
    return verification;
  }
}

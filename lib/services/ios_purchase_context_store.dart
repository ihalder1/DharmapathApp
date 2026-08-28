import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/ios_purchase.dart';
import 'secure_session_storage.dart';
import 'storekit_diagnostics.dart';

abstract interface class IosPurchaseContextStorage {
  Future<void> save(IosPurchaseContext context);
  Future<IosPurchaseContext?> load();
  Future<void> clear();
}

final class IosPurchaseContextStore implements IosPurchaseContextStorage {
  IosPurchaseContextStore({
    SecureKeyValueStore? secureStore,
    StoreKitDiagnostics? diagnostics,
  }) : _secureStore = secureStore ?? FlutterSecureKeyValueStore(),
       _diagnostics = diagnostics;

  static const _contextKey = 'ios_purchase_context_v1';
  static const _linkTokenKey = 'ios_purchase_link_token_v1';
  final SecureKeyValueStore _secureStore;
  final StoreKitDiagnostics? _diagnostics;

  @override
  Future<void> save(IosPurchaseContext context) async {
    _diagnostics?.log('CONTEXT_STORE_SAVE_START', _fields(context));
    final prefs = await SharedPreferences.getInstance();
    final existing = await load();
    if (existing != null && existing.orderId != context.orderId) {
      throw StateError('ios_unresolved_order_conflict');
    }
    await _secureStore.write(_linkTokenKey, context.linkToken);
    await prefs.setString(_contextKey, context.encodeWithoutToken());
    _diagnostics?.log('CONTEXT_STORE_SAVE_END', _fields(context));
  }

  @override
  Future<IosPurchaseContext?> load() async {
    _diagnostics?.log('CONTEXT_STORE_READ_START');
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_contextKey);
    final linkToken = await _secureStore.read(_linkTokenKey);
    if (raw == null || linkToken == null || linkToken.isEmpty) {
      _diagnostics?.log('CONTEXT_STORE_READ_END', {'present': false});
      return null;
    }
    try {
      final context = IosPurchaseContext.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
        linkToken: linkToken,
      );
      if (context.orderId.isEmpty || context.units.isEmpty) return null;
      _diagnostics?.log('CONTEXT_STORE_READ_END', {
        'present': true,
        ..._fields(context),
      });
      return context;
    } catch (error) {
      _diagnostics?.logError(stage: 'context_store_read', error: error);
      return null;
    }
  }

  @override
  Future<void> clear() async {
    _diagnostics?.log('CONTEXT_STORE_CLEAR_START');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_contextKey);
    await _secureStore.delete(_linkTokenKey);
    _diagnostics?.log('CONTEXT_STORE_CLEAR_END');
  }

  Map<String, Object?> _fields(IosPurchaseContext context) => {
    'orderId': StoreKitDiagnostics.redactIdentifier(context.orderId),
    'state': context.state,
    'productIds': context.units.map((item) => item.storeProductId).toList(),
    'quantities': context.cartProducts
        .map((item) => '${item.storeProductId}:${item.quantity}')
        .toList(),
    'linkTokenSuffix': StoreKitDiagnostics.redactIdentifier(context.linkToken),
    'transactionIds': context.units
        .map((item) => StoreKitDiagnostics.redactIdentifier(item.transactionId))
        .toList(),
  };
}

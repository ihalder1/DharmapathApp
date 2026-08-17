import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/ios_purchase.dart';
import 'secure_session_storage.dart';

abstract interface class IosPurchaseContextStorage {
  Future<void> save(IosPurchaseContext context);
  Future<IosPurchaseContext?> load();
  Future<void> clear();
}

final class IosPurchaseContextStore implements IosPurchaseContextStorage {
  IosPurchaseContextStore({SecureKeyValueStore? secureStore})
    : _secureStore = secureStore ?? FlutterSecureKeyValueStore();

  static const _contextKey = 'ios_purchase_context_v1';
  static const _linkTokenKey = 'ios_purchase_link_token_v1';
  final SecureKeyValueStore _secureStore;

  @override
  Future<void> save(IosPurchaseContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await load();
    if (existing != null && existing.orderId != context.orderId) {
      throw StateError('ios_unresolved_order_conflict');
    }
    await _secureStore.write(_linkTokenKey, context.linkToken);
    await prefs.setString(_contextKey, context.encodeWithoutToken());
  }

  @override
  Future<IosPurchaseContext?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_contextKey);
    final linkToken = await _secureStore.read(_linkTokenKey);
    if (raw == null || linkToken == null || linkToken.isEmpty) return null;
    try {
      final context = IosPurchaseContext.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
        linkToken: linkToken,
      );
      if (context.orderId.isEmpty || context.units.isEmpty) return null;
      return context;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_contextKey);
    await _secureStore.delete(_linkTokenKey);
  }
}

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/android_purchase.dart';
import 'secure_session_storage.dart';

final class AndroidPurchaseContextStore {
  AndroidPurchaseContextStore({SecureKeyValueStore? secureStore})
    : _secureStore = secureStore ?? FlutterSecureKeyValueStore();

  static const _contextKey = 'android_purchase_context_v1';
  static const _linkTokenKey = 'android_purchase_link_token_v1';
  final SecureKeyValueStore _secureStore;

  Future<void> save(AndroidPurchaseContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await _secureStore.write(_linkTokenKey, context.linkToken);
    await prefs.setString(_contextKey, context.encodeWithoutToken());
  }

  Future<AndroidPurchaseContext?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_contextKey);
    final linkToken = await _secureStore.read(_linkTokenKey);
    if (raw == null || linkToken == null || linkToken.isEmpty) return null;
    try {
      return AndroidPurchaseContext.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
        linkToken: linkToken,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_contextKey);
    await _secureStore.delete(_linkTokenKey);
  }
}

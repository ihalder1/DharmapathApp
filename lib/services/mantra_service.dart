import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/mantra.dart';
import '../models/ios_purchase.dart';
import '../constants/api_config.dart';
import 'auth_service.dart';
import 'mantra_sync_service.dart';
import 'authenticated_http.dart';
import 'location_pricing_service.dart';
import 'song_service.dart';
import 'cart_quantity_policy.dart' as cart_quantity_policy;

class MantraService {
  static const int maxCartTotalQuantity = 30;

  static List<Mantra> _mantras = [];
  static List<Mantra> _cart = [];

  @visibleForTesting
  static TargetPlatform? debugTargetPlatformOverride;

  static bool get supportsMultipleCartQuantity => cart_quantity_policy
      .supportsMultipleCartQuantity(platform: debugTargetPlatformOverride);

  /// Platform-aware cart ceiling. Android retains its existing 30-item
  /// behavior; only iOS is constrained by the available aggregate SKUs.
  static int get effectiveMaxCartTotalQuantity =>
      cart_quantity_policy.maxCartTotalQuantity(
        existingDefault: maxCartTotalQuantity,
        platform: debugTargetPlatformOverride,
      );

  /// Whether [additional] more unit(s) can be added without exceeding [maxCartTotalQuantity].
  static bool canAddCartUnits([int additional = 1]) {
    if (additional < 1) return false;
    return getCartTotalQuantity() + additional <= effectiveMaxCartTotalQuantity;
  }

  /// Merges GET purchase/songs counts into [source] (does not mutate input list).
  static List<Mantra> applyPurchasedCounts(
    List<Mantra> source,
    Map<String, int> purchasedCounts,
  ) {
    return source.map((mantra) {
      final n = SongService.resolvePurchasedCount(mantra, purchasedCounts);
      if (n > 0) {
        return mantra.copyWith(isBought: true, purchasedCount: n);
      }
      return mantra.copyWith(isBought: false, purchasedCount: 0);
    }).toList();
  }

  /// Re-fetch purchased counts only and update in-memory catalog (no songs sync).
  static Future<List<Mantra>> refreshPurchasedCountsOnly() async {
    final purchasedCounts = await SongService.getPurchasedSongCounts();
    _mantras = applyPurchasedCounts(_mantras, purchasedCounts);
    return List<Mantra>.from(_mantras);
  }

  static Future<List<Mantra>> refreshPurchasedCountsOnlyStrict() async {
    final purchasedCounts = await SongService.getPurchasedSongCountsStrict();
    _mantras = applyPurchasedCounts(_mantras, purchasedCounts);
    return List<Mantra>.from(_mantras);
  }

  /// Load catalog from local metadata, optionally syncing with API first.
  ///
  /// A full load performs only backend-authoritative catalogue reconciliation.
  /// Purchase counts, cart restoration, pricing and asset downloads are separate
  /// enrichment operations so they cannot hold the catalogue render gate.
  ///
  /// When [syncCatalog] is false (after checkout or similar): only
  /// [refreshPurchasedCountsOnly].
  static Future<List<Mantra>> loadMantras({bool syncCatalog = true}) async {
    if (!syncCatalog) {
      return refreshPurchasedCountsOnly();
    }

    try {
      await MantraSyncService.syncMantras();
      await _loadFromLocalJson(restoreCart: false, resolveRegion: false);
      return List<Mantra>.from(_mantras);
    } catch (e, stackTrace) {
      await _loadFromLocalJson(restoreCart: false, resolveRegion: false);
      return List<Mantra>.from(_mantras);
    }
  }

  // Load mantras from local JSON metadata
  static Future<List<Mantra>> _loadFromLocalJson({
    bool restoreCart = true,
    bool resolveRegion = true,
  }) async {
    try {
      final Map<String, dynamic> jsonData =
          await MantraSyncService.loadLocalMetadata();
      final raw = jsonData['mantras'];
      if (raw is! List || raw.isEmpty) {
        throw Exception('metadata mantras missing or empty');
      }

      final pricingRegion = resolveRegion
          ? await LocationPricingService.getPricingRegion()
          : LocationPricingService.cachedRegion;
      _mantras = raw
          .map(
            (json) => Mantra.fromJson(
              json as Map<String, dynamic>,
              region: pricingRegion,
            ),
          )
          .toList();

      for (var mantra in _mantras) {}

      if (restoreCart) await _loadCart();

      return _mantras;
    } catch (e) {
      _mantras = [];
      _cart = [];
      return _mantras;
    }
  }

  static Future<List<Mantra>> restoreCartForCurrentCatalogue() async {
    await _loadCart();
    return List<Mantra>.from(_mantras);
  }

  static Future<List<Mantra>> refreshRegionalPricing() async {
    return _loadFromLocalJson(restoreCart: false, resolveRegion: true);
  }

  static Future<List<Mantra>> reloadPersistedCatalogue() async {
    return _loadFromLocalJson(restoreCart: false, resolveRegion: false);
  }

  // Get all mantras
  static List<Mantra> getMantras() {
    return _mantras;
  }

  // Get cart items
  static List<Mantra> getCart() {
    return _cart;
  }

  /// Frozen row-based input for aggregate iOS checkout. Quantities live on
  /// each distinct row and must never pass through [expandCartForCheckout].
  static List<Mantra> iosAggregateCartSnapshot() =>
      List<Mantra>.from(_cart, growable: false);

  // Add mantra to cart (quantity 1). Returns false if cart is at [maxCartTotalQuantity].
  static Future<bool> addToCart(Mantra mantra) async {
    final existingIndex = _cart.indexWhere((item) => item.name == mantra.name);
    if (existingIndex != -1) {
      if (!supportsMultipleCartQuantity) {
        if (_cart[existingIndex].cartQuantity != 1) {
          _cart[existingIndex] = _cart[existingIndex].copyWith(cartQuantity: 1);
          await _saveCart();
        }
        return false;
      }
      if (!canAddCartUnits(1)) return false;
      _cart[existingIndex] = _cart[existingIndex].copyWith(
        cartQuantity: _cart[existingIndex].cartQuantity + 1,
      );
    } else {
      if (!canAddCartUnits(1)) return false;
      _cart.add(mantra.copyWith(isInCart: true, cartQuantity: 1));
      final index = _mantras.indexWhere((item) => item.name == mantra.name);
      if (index != -1) {
        _mantras[index] = _mantras[index].copyWith(isInCart: true);
      }
    }
    await _saveCart();
    return true;
  }

  static Future<bool> incrementCartQuantity(Mantra mantra) async {
    final index = _cart.indexWhere((item) => item.name == mantra.name);
    if (index == -1) {
      return addToCart(mantra);
    }
    if (!supportsMultipleCartQuantity) {
      if (_cart[index].cartQuantity != 1) {
        _cart[index] = _cart[index].copyWith(cartQuantity: 1);
        await _saveCart();
      }
      return false;
    }
    if (!canAddCartUnits(1)) return false;
    _cart[index] = _cart[index].copyWith(
      cartQuantity: _cart[index].cartQuantity + 1,
    );
    await _saveCart();
    return true;
  }

  static Future<void> decrementCartQuantity(Mantra mantra) async {
    final index = _cart.indexWhere((item) => item.name == mantra.name);
    if (index == -1) return;
    final qty = _cart[index].cartQuantity;
    if (!supportsMultipleCartQuantity || qty <= 1) {
      await removeFromCart(mantra);
    } else {
      _cart[index] = _cart[index].copyWith(cartQuantity: qty - 1);
      await _saveCart();
    }
  }

  static int getCartQuantity(Mantra mantra) {
    final index = _cart.indexWhere((item) => item.name == mantra.name);
    if (index == -1) return 0;
    return _cart[index].cartQuantity;
  }

  /// Total units across all cart lines (e.g. 2 mantras × 3 each = 6).
  static int getCartTotalQuantity() {
    if (!supportsMultipleCartQuantity) return _cart.length;
    return _cart.fold(0, (sum, m) => sum + m.cartQuantity);
  }

  /// One entry per purchased unit (for payment APIs and song_ids).
  static List<Mantra> expandCartForCheckout() {
    if (!supportsMultipleCartQuantity) {
      return _cart
          .map((mantra) => mantra.copyWith(cartQuantity: 1))
          .toList(growable: false);
    }
    final expanded = <Mantra>[];
    for (final m in _cart) {
      for (var i = 0; i < m.cartQuantity; i++) {
        expanded.add(m);
      }
    }
    return expanded;
  }

  // Remove mantra from cart
  static Future<void> removeFromCart(Mantra mantra) async {
    _cart.removeWhere((item) => item.name == mantra.name);
    // Update the main list to reflect cart status
    final index = _mantras.indexWhere((item) => item.name == mantra.name);
    if (index != -1) {
      _mantras[index] = _mantras[index].copyWith(isInCart: false);
    }
    // Save cart to SharedPreferences
    await _saveCart();
  }

  // Get cart total
  static double getCartTotal() {
    return _cart.fold(0.0, (total, mantra) => total + mantra.lineTotal);
  }

  static String getCartCurrencyCode() {
    if (_cart.isNotEmpty) {
      return _cart.first.currencyCode;
    }
    if (_mantras.isNotEmpty) {
      return _mantras.first.currencyCode;
    }
    final region = LocationPricingService.cachedRegion;
    if (region != null) {
      return LocationPricingService.currencyCodeForRegion(region);
    }
    return 'USD';
  }

  // Clear cart
  static Future<void> clearCart() async {
    _cart.clear();
    // Update the main list to reflect cart status
    for (int i = 0; i < _mantras.length; i++) {
      _mantras[i] = _mantras[i].copyWith(isInCart: false);
    }
    // Save cart to SharedPreferences
    await _saveCart();
  }

  /// Removes only Android cart rows completed by a paid Google Play order.
  static Future<void> removeCartProductsByStoreIds(
    Iterable<String> storeProductIds,
  ) async {
    final ids = storeProductIds.map((id) => id.trim()).toSet();
    if (ids.isEmpty) return;
    _cart.removeWhere(
      (item) => ids.contains(item.storeProductIdAndroid?.trim()),
    );
    for (var index = 0; index < _mantras.length; index++) {
      final storeId = _mantras[index].storeProductIdAndroid?.trim();
      if (storeId != null && ids.contains(storeId)) {
        _mantras[index] = _mantras[index].copyWith(isInCart: false);
      }
    }
    await _saveCart();
  }

  /// Removes only iOS cart rows accepted by backend StoreKit verification.
  static Future<void> removeIosCartProductsByStoreIds(
    Iterable<String> storeProductIds,
  ) async {
    final ids = storeProductIds.map((id) => id.trim()).toSet();
    if (ids.isEmpty) return;
    _cart.removeWhere((item) => ids.contains(item.storeProductIdIos?.trim()));
    for (var index = 0; index < _mantras.length; index++) {
      final storeId = _mantras[index].storeProductIdIos?.trim();
      if (storeId != null && ids.contains(storeId)) {
        _mantras[index] = _mantras[index].copyWith(isInCart: false);
      }
    }
    await _saveCart();
  }

  /// Removes only backend-verified iOS consumable units, retaining the rest
  /// of a partially completed quantity in the cart.
  static Future<void> consumeIosCartProductUnits(
    String storeProductId,
    int quantity,
  ) async {
    final id = storeProductId.trim();
    if (id.isEmpty || quantity < 1) return;
    for (var index = 0; index < _cart.length; index++) {
      final item = _cart[index];
      if (item.storeProductIdIos?.trim() != id) continue;
      final remaining = item.cartQuantity - quantity;
      if (remaining > 0) {
        _cart[index] = item.copyWith(cartQuantity: remaining);
        for (
          var mantraIndex = 0;
          mantraIndex < _mantras.length;
          mantraIndex++
        ) {
          if (_mantras[mantraIndex].storeProductIdIos?.trim() == id) {
            _mantras[mantraIndex] = _mantras[mantraIndex].copyWith(
              isInCart: true,
              cartQuantity: remaining,
            );
          }
        }
      } else {
        _cart.removeAt(index);
        for (
          var mantraIndex = 0;
          mantraIndex < _mantras.length;
          mantraIndex++
        ) {
          if (_mantras[mantraIndex].storeProductIdIos?.trim() == id) {
            _mantras[mantraIndex] = _mantras[mantraIndex].copyWith(
              isInCart: false,
              cartQuantity: 1,
            );
          }
        }
      }
      await _saveCart();
      return;
    }
  }

  /// Removes/decrements the exact internal song quantities represented by a
  /// backend-paid aggregate iOS order. Aggregate StoreKit IDs never enter the
  /// catalogue or cart matching path.
  static Future<void> consumeIosCartProducts(
    Iterable<IosCartProduct> purchased,
  ) async {
    final quantities = <String, int>{};
    for (final item in purchased) {
      final id = item.internalProductId.trim();
      if (id.isEmpty || item.quantity < 1) continue;
      quantities.update(
        id,
        (value) => value + item.quantity,
        ifAbsent: () => item.quantity,
      );
    }
    if (quantities.isEmpty) return;
    for (var index = _cart.length - 1; index >= 0; index--) {
      final item = _cart[index];
      final purchasedQuantity = quantities[item.internalProductId.trim()];
      if (purchasedQuantity == null) continue;
      final remaining = item.cartQuantity - purchasedQuantity;
      if (remaining > 0) {
        _cart[index] = item.copyWith(cartQuantity: remaining);
      } else {
        _cart.removeAt(index);
      }
    }
    for (var index = 0; index < _mantras.length; index++) {
      final cartIndex = _cart.indexWhere(
        (item) => item.internalProductId == _mantras[index].internalProductId,
      );
      if (!quantities.containsKey(_mantras[index].internalProductId)) continue;
      _mantras[index] = _mantras[index].copyWith(
        isInCart: cartIndex >= 0,
        cartQuantity: cartIndex >= 0 ? _cart[cartIndex].cartQuantity : 1,
      );
    }
    await _saveCart();
  }

  // Save cart to SharedPreferences
  static Future<void> _saveCart() async {
    try {
      if (!supportsMultipleCartQuantity) {
        final seen = <String>{};
        _cart = _cart
            .where((mantra) => seen.add(mantra.name))
            .map((mantra) => mantra.copyWith(cartQuantity: 1))
            .toList();
      }
      final prefs = await SharedPreferences.getInstance();
      final cartNames = _cart.map((m) => m.name).toList();
      await prefs.setStringList('cart_items', cartNames);
      final quantities = <String, int>{
        for (final m in _cart) m.name: m.cartQuantity,
      };
      await prefs.setString('cart_quantities', jsonEncode(quantities));
    } catch (e) {}
  }

  /// Drops units from the end of the cart until total ≤ [maxCartTotalQuantity].
  static void _trimCartToMaxLimit() {
    while (getCartTotalQuantity() > effectiveMaxCartTotalQuantity &&
        _cart.isNotEmpty) {
      final last = _cart.length - 1;
      final qty = _cart[last].cartQuantity;
      if (qty <= 1) {
        final name = _cart[last].name;
        _cart.removeAt(last);
        final index = _mantras.indexWhere((item) => item.name == name);
        if (index != -1) {
          _mantras[index] = _mantras[index].copyWith(isInCart: false);
        }
      } else {
        _cart[last] = _cart[last].copyWith(cartQuantity: qty - 1);
      }
    }
  }

  static Map<String, int> _readSavedQuantities(SharedPreferences prefs) {
    final raw = prefs.getString('cart_quantities');
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map(
        (key, value) => MapEntry(
          key.toString(),
          value is int ? value : int.tryParse(value.toString()) ?? 1,
        ),
      );
    } catch (_) {
      return {};
    }
  }

  // Load cart from SharedPreferences
  static Future<void> _loadCart() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cartNames = prefs.getStringList('cart_items') ?? [];
      final savedQuantities = _readSavedQuantities(prefs);

      if (cartNames.isEmpty) {
        return;
      }

      _cart.clear();
      final restoredNames = <String>{};
      for (final name in cartNames) {
        if (!supportsMultipleCartQuantity && !restoredNames.add(name)) {
          continue;
        }
        final mantra = _mantras.firstWhere(
          (m) => m.name == name,
          orElse: () =>
              Mantra(name: name, mantraFile: '', icon: '', price: 0.0),
        );

        if (mantra.mantraFile.isNotEmpty) {
          final qty = savedQuantities[name] ?? 1;
          _cart.add(
            mantra.copyWith(
              isInCart: true,
              cartQuantity: cart_quantity_policy.normalizedCartQuantity(
                qty,
                platform: debugTargetPlatformOverride,
              ),
            ),
          );
          final index = _mantras.indexWhere((item) => item.name == mantra.name);
          if (index != -1) {
            _mantras[index] = _mantras[index].copyWith(isInCart: true);
          }
        } else {}
      }

      _trimCartToMaxLimit();
      await _saveCart();
    } catch (e) {}
  }

  // Mark mantra as purchased
  static Future<void> markAsPurchased(Mantra mantra) async {
    // First try exact match by mantraFile (case-insensitive)
    int index = _mantras.indexWhere(
      (m) =>
          m.mantraFile.toLowerCase().trim() ==
          mantra.mantraFile.toLowerCase().trim(),
    );

    // If not found, try matching by name
    if (index == -1) {
      index = _mantras.indexWhere(
        (m) => m.name.toLowerCase().trim() == mantra.name.toLowerCase().trim(),
      );
    }

    // If still not found, try partial match on mantraFile
    if (index == -1) {
      final searchFile = mantra.mantraFile.toLowerCase().trim();
      index = _mantras.indexWhere(
        (m) =>
            m.mantraFile.toLowerCase().trim().contains(searchFile) ||
            searchFile.contains(m.mantraFile.toLowerCase().trim()),
      );
    }

    if (index != -1) {
      _mantras[index] = _mantras[index].copyWith(
        isBought: true,
        isInCart: false,
        purchasedCount: _mantras[index].purchasedCount + 1,
      );

      // Remove from cart if present
      _cart.removeWhere((item) => item.name == mantra.name);

      // Save cart after removing purchased item
      await _saveCart();
    } else {
      for (int i = 0; i < _mantras.length; i++) {}
    }
  }

  // Check if mantra is in cart
  static bool isInCart(Mantra mantra) {
    return _cart.any((item) => item.name == mantra.name);
  }

  /// Maps local `mantra_file` values (e.g. `F-SURYA-001.mp3`) to API `song_ids` (`F-SURYA-001`).
  static List<String> songIdsForCreateJob(List<String> mantraFileIds) {
    return mantraFileIds.map((id) {
      final t = id.trim();
      final lower = t.toLowerCase();
      if (lower.endsWith('.mp3')) return t.substring(0, t.length - 4);
      return t;
    }).toList();
  }

  // Generate mantra in user's voice (async job — POST create-job)
  static Future<bool> generateMantraInVoice({
    required String recordingId,
    required List<String> mantraIds,
  }) async {
    try {
      final authService = AuthService();

      await authService.ensureValidAccessToken();
      final accessToken = authService.accessToken;
      if (accessToken == null || accessToken.isEmpty) {
        return false;
      }

      final userFields = authService.getCreateJobUserFields();
      if (userFields == null) {
        return false;
      }

      final url = Uri.parse(
        '${ApiConfig.createJobBaseUrl}${ApiConfig.createJobEndpoint}',
      );

      final songIds = songIdsForCreateJob(mantraIds);

      final bodyMap = <String, dynamic>{
        'userId': userFields['userId'],
        'email': userFields['email'],
        'recording_id': recordingId,
        'song_ids': songIds,
      };

      final response = await AuthenticatedHttp.post(
        url,
        body: json.encode(bodyMap),
        mergeHeaders: {'Authorization': 'Bearer $accessToken'},
      );

      final ok =
          response.statusCode == 200 ||
          response.statusCode == 201 ||
          response.statusCode == 202;
      if (ok) {
        return true;
      }
      return false;
    } catch (e, stackTrace) {
      return false;
    }
  }
}

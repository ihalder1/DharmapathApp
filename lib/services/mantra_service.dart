import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/mantra.dart';
import '../constants/api_config.dart';
import 'auth_service.dart';
import 'mantra_sync_service.dart';
import 'authenticated_http.dart';
import 'location_pricing_service.dart';

class MantraService {
  static List<Mantra> _mantras = [];
  static List<Mantra> _cart = [];

  // Load mantras: Always sync with API first, then load from local metadata.json
  static Future<List<Mantra>> loadMantras({bool syncFirst = true}) async {
    try {
      // Always sync with API first to update local metadata.json
      print('═══════════════════════════════════════════════════════════');
      print('🔄 MANTRA SERVICE: Starting load process');
      print('═══════════════════════════════════════════════════════════');
      print('🔄 Syncing mantras with API first...');
      
      final syncResult = await MantraSyncService.syncMantras();
      print('🔄 Sync completed. Result: $syncResult');
      
      // Always load from local JSON after sync (never load directly from API)
      print('═══════════════════════════════════════════════════════════');
      print('📂 Loading mantras from local metadata.json...');
      print('═══════════════════════════════════════════════════════════');
      final mantras = await _loadFromLocalJson();
      print('✅ Successfully loaded ${mantras.length} mantras from LOCAL metadata.json');
      print('═══════════════════════════════════════════════════════════');
      return mantras;
    } catch (e, stackTrace) {
      print('❌ Error during sync or loading: $e');
      print('Stack trace: $stackTrace');
      print('Falling back to local JSON...');
      // Even if sync fails, try to load from local
      return await _loadFromLocalJson();
    }
  }

  // Load mantras from local JSON metadata
  static Future<List<Mantra>> _loadFromLocalJson() async {
    try {
      print('Attempting to load mantras from metadata.json');

      final Map<String, dynamic> jsonData =
          await MantraSyncService.loadLocalMetadata();
      final raw = jsonData['mantras'];
      if (raw is! List || raw.isEmpty) {
        throw Exception('metadata mantras missing or empty');
      }

      final pricingRegion = await LocationPricingService.getPricingRegion();
      _mantras = raw
          .map((json) => Mantra.fromJson(
                json as Map<String, dynamic>,
                region: pricingRegion,
              ))
          .toList();

      print('Successfully created ${_mantras.length} mantra objects');
      for (var mantra in _mantras) {
        print('Mantra: ${mantra.name} - ${mantra.mantraFile} - ${mantra.icon}');
      }

      await _loadCart();

      return _mantras;
    } catch (e) {
      print('Error loading mantras from local JSON: $e');
      print('Error type: ${e.runtimeType}');
      
      _mantras = [];
      _cart = [];
      return _mantras;
    }
  }

  // Get all mantras
  static List<Mantra> getMantras() {
    return _mantras;
  }

  // Get cart items
  static List<Mantra> getCart() {
    return _cart;
  }

  // Add mantra to cart (quantity 1)
  static Future<void> addToCart(Mantra mantra) async {
    final existingIndex = _cart.indexWhere((item) => item.name == mantra.name);
    if (existingIndex != -1) {
      _cart[existingIndex] = _cart[existingIndex].copyWith(
        cartQuantity: _cart[existingIndex].cartQuantity + 1,
      );
    } else {
      _cart.add(mantra.copyWith(isInCart: true, cartQuantity: 1));
      final index = _mantras.indexWhere((item) => item.name == mantra.name);
      if (index != -1) {
        _mantras[index] = _mantras[index].copyWith(isInCart: true);
      }
    }
    await _saveCart();
  }

  static Future<void> incrementCartQuantity(Mantra mantra) async {
    final index = _cart.indexWhere((item) => item.name == mantra.name);
    if (index == -1) {
      await addToCart(mantra);
      return;
    }
    _cart[index] = _cart[index].copyWith(
      cartQuantity: _cart[index].cartQuantity + 1,
    );
    await _saveCart();
  }

  static Future<void> decrementCartQuantity(Mantra mantra) async {
    final index = _cart.indexWhere((item) => item.name == mantra.name);
    if (index == -1) return;
    final qty = _cart[index].cartQuantity;
    if (qty <= 1) {
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
    return _cart.fold(0, (sum, m) => sum + m.cartQuantity);
  }

  /// One entry per purchased unit (for payment APIs and song_ids).
  static List<Mantra> expandCartForCheckout() {
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

  // Save cart to SharedPreferences
  static Future<void> _saveCart() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cartNames = _cart.map((m) => m.name).toList();
      await prefs.setStringList('cart_items', cartNames);
      final quantities = <String, int>{
        for (final m in _cart) m.name: m.cartQuantity,
      };
      await prefs.setString('cart_quantities', jsonEncode(quantities));
      print(
        '✅ Cart saved: ${cartNames.length} line(s), ${getCartTotalQuantity()} unit(s)',
      );
    } catch (e) {
      print('⚠️ Error saving cart to SharedPreferences: $e');
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
        print('📦 No saved cart found');
        return;
      }

      print('📦 Loading cart from SharedPreferences: ${cartNames.length} items');

      _cart.clear();
      for (final name in cartNames) {
        final mantra = _mantras.firstWhere(
          (m) => m.name == name,
          orElse: () => Mantra(
            name: name,
            mantraFile: '',
            icon: '',
            price: 0.0,
          ),
        );

        if (mantra.mantraFile.isNotEmpty) {
          final qty = savedQuantities[name] ?? 1;
          _cart.add(
            mantra.copyWith(isInCart: true, cartQuantity: qty < 1 ? 1 : qty),
          );
          final index = _mantras.indexWhere((item) => item.name == mantra.name);
          if (index != -1) {
            _mantras[index] = _mantras[index].copyWith(isInCart: true);
          }
        } else {
          print('⚠️ Skipping cart item "$name" - mantra not found in catalog');
        }
      }

      await _saveCart();

      print('✅ Cart loaded: ${_cart.length} line(s), ${getCartTotalQuantity()} unit(s)');
    } catch (e) {
      print('⚠️ Error loading cart from SharedPreferences: $e');
    }
  }

  // Mark mantra as purchased
  static Future<void> markAsPurchased(Mantra mantra) async {
    print('═══════════════════════════════════════════════════════════');
    print('🛒 MARKING MANTRA AS PURCHASED');
    print('═══════════════════════════════════════════════════════════');
    print('Mantra to mark: ${mantra.name}');
    print('Mantra file: ${mantra.mantraFile}');
    print('Current isBought: ${mantra.isBought}');
    print('Total mantras in list: ${_mantras.length}');
    
    // First try exact match by mantraFile (case-insensitive)
    int index = _mantras.indexWhere((m) => 
      m.mantraFile.toLowerCase().trim() == mantra.mantraFile.toLowerCase().trim()
    );
    
    // If not found, try matching by name
    if (index == -1) {
      print('Not found by mantraFile, trying name match...');
      index = _mantras.indexWhere((m) => 
        m.name.toLowerCase().trim() == mantra.name.toLowerCase().trim()
      );
    }
    
    // If still not found, try partial match on mantraFile
    if (index == -1) {
      print('Not found by name, trying partial mantraFile match...');
      final searchFile = mantra.mantraFile.toLowerCase().trim();
      index = _mantras.indexWhere((m) => 
        m.mantraFile.toLowerCase().trim().contains(searchFile) ||
        searchFile.contains(m.mantraFile.toLowerCase().trim())
      );
    }
    
    if (index != -1) {
      print('✅ Found mantra at index $index');
      print('   Before: ${_mantras[index].name} - isBought: ${_mantras[index].isBought}');
      _mantras[index] = _mantras[index].copyWith(
        isBought: true,
        isInCart: false,
        purchasedCount: _mantras[index].purchasedCount + 1,
      );
      
      // Remove from cart if present
      _cart.removeWhere((item) => item.name == mantra.name);
      
      // Save cart after removing purchased item
      await _saveCart();
      
      print('   After: ${_mantras[index].name} - isBought: ${_mantras[index].isBought}');
      print('═══════════════════════════════════════════════════════════');
    } else {
      print('❌ WARNING: Could not find mantra to mark as purchased!');
      print('   Searching for: ${mantra.name} (${mantra.mantraFile})');
      print('   Available mantras:');
      for (int i = 0; i < _mantras.length; i++) {
        print('     [$i] ${_mantras[i].name} (${_mantras[i].mantraFile}) - isBought: ${_mantras[i].isBought}');
      }
      print('═══════════════════════════════════════════════════════════');
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

      final userFields = authService.getCreateJobUserFields();
      if (userFields == null) {
        print('❌ ERROR: Could not resolve userId from JWT / session for create-job');
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

      final prettyBody = const JsonEncoder.withIndent('  ').convert(bodyMap);

      print('═══════════════════════════════════════════════════════════');
      print('🎤 CREATE MANTRA JOB (POST create-job)');
      print('═══════════════════════════════════════════════════════════');
      print('📤 REQUEST JSON (verification):');
      print(prettyBody);
      print('📤 URL: $url');
      print('   Method: POST (x-api-key only; no Authorization header)');
      print('═══════════════════════════════════════════════════════════');

      final response = await AuthenticatedHttp.postCreateJob(
        url,
        body: json.encode(bodyMap),
      );

      print('═══════════════════════════════════════════════════════════');
      print('📥 RESPONSE:');
      print('   Status Code: ${response.statusCode}');
      print('   Response Body: ${response.body}');
      print('═══════════════════════════════════════════════════════════');

      final ok = response.statusCode == 200 ||
          response.statusCode == 201 ||
          response.statusCode == 202;
      if (ok) {
        print('✅ Create-job accepted');
        return true;
      }
      print('❌ Create-job failed: ${response.statusCode}');
      return false;
    } catch (e, stackTrace) {
      print('❌ ERROR generating mantra in voice: $e');
      print('   StackTrace: $stackTrace');
      return false;
    }
  }
}

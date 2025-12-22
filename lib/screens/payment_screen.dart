import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:provider/provider.dart';
import '../constants/api_config.dart';
import '../constants/app_colors.dart';
import '../services/payment_service.dart';
import '../services/auth_service.dart';
import '../services/mantra_service.dart';
import '../models/mantra.dart';

class PaymentScreen extends StatefulWidget {
  final int totalAmount;
  final List<Mantra> cartItems;

  const PaymentScreen({
    super.key,
    required this.totalAmount,
    required this.cartItems,
  });

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  final _formKey = GlobalKey<FormState>();
  final _cardController = CardFormEditController();
  bool _isLoading = false;
  String? _errorMessage;
  String? _clientSecret;
  String? _paymentIntentId;
  bool _isCardComplete = false;

  @override
  void initState() {
    super.initState();
    _initializePayment();
    // Listen to card details changes
    _cardController.addListener(_onCardDetailsChanged);
    // Ensure CardFormField is properly initialized on Android
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {
          // Force rebuild to ensure CardFormField renders on Android
        });
      }
    });
  }

  @override
  void dispose() {
    _cardController.removeListener(_onCardDetailsChanged);
    _cardController.dispose();
    super.dispose();
  }

  void _onCardDetailsChanged() {
    setState(() {
      _isCardComplete = _cardController.details.complete;
    });
  }

  Future<void> _initializePayment() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Check if cart is empty
      if (widget.cartItems.isEmpty) {
        throw Exception('Cart is empty. Please add items to cart first.');
      }

      final authService = Provider.of<AuthService>(context, listen: false);
      final currentUser = authService.currentUser;
      
      if (currentUser == null) {
        throw Exception('User not authenticated');
      }

      // Generate random order ID
      final random = Random();
      final orderId = 'order_${DateTime.now().millisecondsSinceEpoch}_${random.nextInt(10000)}';
      
      // Get first mantra for product details (or combine if multiple)
      Mantra firstMantra = widget.cartItems.first;
      
      // Validate mantra file name
      if (firstMantra.mantraFile.isEmpty) {
        throw Exception('Invalid mantra file name');
      }
      
      // Extract product ID from mantraFile (file name without .mp3)
      String productId = firstMantra.mantraFile;
      if (productId.toLowerCase().endsWith('.mp3')) {
        productId = productId.substring(0, productId.length - 4);
      }
      
      // Product name is mantraFile with .mp3
      String productName = firstMantra.mantraFile;
      if (!productName.toLowerCase().endsWith('.mp3')) {
        productName = '$productName.mp3';
      }
      
      // If multiple mantras, combine product names
      if (widget.cartItems.length > 1) {
        productName = widget.cartItems.map((m) {
          String fileName = m.mantraFile;
          if (!fileName.toLowerCase().endsWith('.mp3')) {
            fileName = '$fileName.mp3';
          }
          return fileName;
        }).join(', ');
      }

      print('📦 PAYMENT DETAILS:');
      print('   Order ID: $orderId');
      print('   Product ID: $productId');
      print('   Product Name: $productName');
      print('   Cart Items: ${widget.cartItems.length}');

      // Create payment intent with backend
      final paymentIntentData = await PaymentService.createPaymentIntent(
        amount: widget.totalAmount * 100, // Convert to cents
        currency: 'aud',
        productId: productId,
        productName: productName,
        customerEmail: currentUser.email,
        metadata: {
          'orderId': orderId,
          'userId': currentUser.id,
        },
      );

      if (paymentIntentData == null || paymentIntentData['clientSecret'] == null) {
        throw Exception('Failed to create payment intent');
      }

      _clientSecret = paymentIntentData['clientSecret'] as String;
      _paymentIntentId = paymentIntentData['paymentIntentId'] as String;

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to initialize payment: ${e.toString()}';
      });
    }
  }

  Future<void> _handlePayment() async {
    if (_formKey.currentState == null || !_formKey.currentState!.validate()) {
      return;
    }

    if (_clientSecret == null || _paymentIntentId == null) {
      setState(() {
        _errorMessage = 'Payment not initialized. Please try again.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      print('═══════════════════════════════════════════════════════════');
      print('💳 STRIPE PAYMENT CONFIRMATION START');
      print('═══════════════════════════════════════════════════════════');
      print('   Client Secret: $_clientSecret');
      print('   Payment Intent ID: $_paymentIntentId');

      // Get payment method from card
      final cardDetails = _cardController.details;
      
      if (!cardDetails.complete) {
        throw Exception('Please complete all card details');
      }

      print('📤 STRIPE CONFIRM PAYMENT:');
      print('   Card Details Complete: ${cardDetails.complete}');

      // Create payment method params from card details
      final paymentMethodParams = PaymentMethodParams.card(
        paymentMethodData: PaymentMethodData(
          billingDetails: BillingDetails(
            email: Provider.of<AuthService>(context, listen: false).currentUser?.email,
          ),
        ),
      );

      final paymentIntent = await Stripe.instance.confirmPayment(
        paymentIntentClientSecret: _clientSecret!,
        data: paymentMethodParams,
      );

      print('📥 STRIPE PAYMENT RESULT:');
      print('   Status: ${paymentIntent.status}');
      print('   Payment Intent ID: ${paymentIntent.id}');

      // Check if payment succeeded - compare enum directly
      if (paymentIntent.status.toString().contains('Succeeded')) {
        print('✅ STRIPE PAYMENT SUCCEEDED');
        print('═══════════════════════════════════════════════════════════');

        // Verify payment with backend
        final backendConfirmed = await PaymentService.confirmPayment(
          paymentIntentId: _paymentIntentId!,
        );

        if (backendConfirmed) {
          print('✅ BACKEND PAYMENT CONFIRMED');
          print('═══════════════════════════════════════════════════════════');

          // Mark mantras as purchased
          print('📦 Marking ${widget.cartItems.length} mantras as purchased...');
          for (var mantra in widget.cartItems) {
            print('   - ${mantra.name} (${mantra.mantraFile})');
            MantraService.markAsPurchased(mantra);
          }
          
          // Verify mantras were marked
          final allMantras = MantraService.getMantras();
          final purchasedCount = allMantras.where((m) => m.isBought).length;
          print('✅ Verification: ${purchasedCount} mantras are now marked as purchased');

          // Clear cart
          MantraService.clearCart();

          if (mounted && context.mounted) {
            // Return to previous screen with success result
            Navigator.of(context).pop(true);
            
            // Show success message
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Payment successful! Your purchase is complete.'),
                backgroundColor: Colors.green,
                duration: Duration(seconds: 3),
              ),
            );
          }
        } else {
          throw Exception('Backend payment verification failed');
        }
      } else {
        throw Exception('Payment failed with status: ${paymentIntent.status}');
      }
    } on StripeException catch (e) {
      print('❌ STRIPE PAYMENT ERROR:');
      print('   Error Code: ${e.error.code}');
      print('   Error Message: ${e.error.message}');
      print('   Error Type: ${e.error.type}');
      print('═══════════════════════════════════════════════════════════');
      
      setState(() {
        _isLoading = false;
        _errorMessage = e.error.message ?? 'Payment failed. Please try again.';
      });
    } catch (e, stackTrace) {
      print('❌ PAYMENT ERROR:');
      print('   Error: $e');
      print('   StackTrace: $stackTrace');
      print('═══════════════════════════════════════════════════════════');
      
      setState(() {
        _isLoading = false;
        _errorMessage = 'Payment failed: ${e.toString()}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Payment'),
        backgroundColor: AppColors.primarySaffron,
        foregroundColor: Colors.white,
      ),
      body: _isLoading && _clientSecret == null
          ? const Center(
              child: CircularProgressIndicator(),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Order Summary
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.primarySaffron.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Order Summary',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${widget.cartItems.length} item${widget.cartItems.length != 1 ? 's' : ''}',
                            style: const TextStyle(fontSize: 14),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Total:',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                '₹${widget.totalAmount}',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primarySaffron,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Card Input
                    const Text(
                      'Card Details',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Wrap CardFormField in Container with explicit constraints for Android compatibility
                    Container(
                      constraints: const BoxConstraints(
                        minHeight: 200,
                        maxHeight: 250,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey, width: 1),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: CardFormField(
                        controller: _cardController,
                        style: CardFormStyle(
                          backgroundColor: Colors.white,
                          borderColor: Colors.transparent, // Use transparent since container has border
                          borderRadius: 12,
                          borderWidth: 0, // No border on CardFormField itself
                          textColor: Colors.black,
                          placeholderColor: Colors.grey,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (!_cardController.details.complete && _cardController.details.number != null)
                      const Text(
                        'Please complete all card details',
                        style: TextStyle(
                          color: Colors.orange,
                          fontSize: 12,
                        ),
                      ),
                    const SizedBox(height: 24),

                    // Error Message
                    if (_errorMessage != null)
                      Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline, color: Colors.red),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                      ),

                    // Pay Button
                    ElevatedButton(
                      onPressed: (_isLoading || !_isCardComplete) ? null : _handlePayment,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: (_isLoading || !_isCardComplete) 
                            ? Colors.grey 
                            : AppColors.primarySaffron,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : Text(
                              'Pay ₹${widget.totalAmount}',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}


import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:provider/provider.dart';
import '../constants/app_colors.dart';
import '../services/payment_service.dart';
import '../services/auth_service.dart';
import '../services/mantra_service.dart';
import '../services/notification_service.dart';
import '../services/song_service.dart';
import '../models/mantra.dart';
import 'stripe_checkout_webview_screen.dart';

enum _PaymentPhase {
  /// INR: choose UPI vs card. Non-INR skips to [cardDetails].
  selectMethod,

  /// Stripe card form only.
  cardDetails,
}

/// Card: Stripe PaymentIntent + [CardFormField] + [Stripe.instance.confirmPayment].
/// UPI (INR): Stripe Checkout Session in [StripeCheckoutWebViewScreen].
class PaymentScreen extends StatefulWidget {
  final double totalAmount;
  final String currencyCode;
  final List<Mantra> cartItems;

  const PaymentScreen({
    super.key,
    required this.totalAmount,
    required this.currencyCode,
    required this.cartItems,
  });

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  bool _isLoading = false;
  bool _paymentScreenReady = false;
  _PaymentPhase _phase = _PaymentPhase.selectMethod;
  /// `upi` | `card` | `verify` — which control shows a spinner.
  String? _busyAction;
  String? _errorMessage;
  String? _clientSecret;
  String? _paymentIntentId;

  final CardFormEditController _cardFormController = CardFormEditController();
  bool _cardDetailsComplete = false;

  String get _formattedAmountDisplay =>
      Mantra.formatMoney(widget.totalAmount, widget.currencyCode);

  bool get _isInr => widget.currencyCode.toUpperCase() == 'INR';

  @override
  void initState() {
    super.initState();
    _bootstrapPaymentScreen();
  }

  @override
  void dispose() {
    _cardFormController.dispose();
    super.dispose();
  }

  Future<void> _bootstrapPaymentScreen() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await _validateCartAndUser();
      if (mounted) {
        setState(() {
          _isLoading = false;
          _paymentScreenReady = true;
          if (!_isInr) {
            _phase = _PaymentPhase.cardDetails;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _paymentScreenReady = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _validateCartAndUser() async {
    if (widget.cartItems.isEmpty) {
      throw Exception('Cart is empty. Please add items to cart first.');
    }
    final authService = Provider.of<AuthService>(context, listen: false);
    if (authService.currentUser == null) {
      throw Exception('User not authenticated');
    }
    final first = widget.cartItems.first;
    if (first.mantraFile.isEmpty) {
      throw Exception('Invalid mantra file name');
    }
    final expectedCurrency = widget.currencyCode.toUpperCase();
    for (final item in widget.cartItems) {
      if (item.currencyCode.toUpperCase() != expectedCurrency) {
        throw Exception(
          'Cart contains mixed currencies. Please clear the cart and add items again.',
        );
      }
    }
  }

  Future<({
    String orderId,
    String productId,
    String productName,
    String customerEmail,
    String userId,
  })> _orderContext() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final currentUser = authService.currentUser;
    if (currentUser == null) {
      throw Exception('User not authenticated');
    }

    final random = Random();
    final orderId =
        'order_${DateTime.now().millisecondsSinceEpoch}_${random.nextInt(10000)}';

    Mantra firstMantra = widget.cartItems.first;
    String productId = firstMantra.mantraFile;
    if (productId.toLowerCase().endsWith('.mp3')) {
      productId = productId.substring(0, productId.length - 4);
    }

    String productName = firstMantra.mantraFile;
    if (!productName.toLowerCase().endsWith('.mp3')) {
      productName = '$productName.mp3';
    }

    if (widget.cartItems.length > 1) {
      productName = widget.cartItems.map((m) {
        String fileName = m.mantraFile;
        if (!fileName.toLowerCase().endsWith('.mp3')) {
          fileName = '$fileName.mp3';
        }
        return fileName;
      }).join(', ');
    }

    return (
      orderId: orderId,
      productId: productId,
      productName: productName,
      customerEmail: currentUser.email,
      userId: currentUser.id,
    );
  }

  Future<void> _ensurePaymentIntentForCard() async {
    if (_clientSecret != null && _paymentIntentId != null) return;

    final products = _checkoutProducts();
    if (products.isEmpty) {
      throw Exception(
        'No valid items to checkout. Each item needs a song id and price.',
      );
    }

    final paymentIntentData = await PaymentService.createPaymentIntent(
      currency: widget.currencyCode,
      products: products,
      paymentMethodTypes: const ['card'],
    );

    if (paymentIntentData == null ||
        paymentIntentData['clientSecret'] == null) {
      throw Exception('Failed to create payment intent');
    }

    _clientSecret = paymentIntentData['clientSecret'] as String;
    _paymentIntentId = paymentIntentData['paymentIntentId'] as String;
  }

  String? _stringFrom(Map<String, dynamic> map, List<String> keys) {
    for (final k in keys) {
      final v = map[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  bool _paymentIntentStatusSucceeded(Map<String, dynamic>? statusBody) {
    if (statusBody == null) return false;
    final nested = statusBody['data'];
    final Map<String, dynamic> map =
        nested is Map<String, dynamic> ? nested : statusBody;
    final s = map['status']?.toString().toLowerCase();
    return s == 'succeeded' || s == 'paid';
  }

  Future<void> _verifyCardOnBackendThenFinish() async {
    final id = _paymentIntentId;
    if (id == null) {
      throw Exception('Missing payment intent');
    }

    final confirmed = await PaymentService.confirmPayment(paymentIntentId: id);
    if (!confirmed) {
      throw Exception('Backend payment verification failed');
    }

    final statusBody = await PaymentService.getPaymentStatus(paymentIntentId: id);
    if (!_paymentIntentStatusSucceeded(statusBody)) {
      throw Exception('Payment is not completed on the server yet');
    }

    await _finalizePurchase(transactionId: id);
  }

  /// After Stripe + backend confirm paid (card or UPI verify-session).
  Future<void> _finalizePurchase({required String transactionId}) async {
    try {
      final songIds = widget.cartItems.map((mantra) {
        return SongService.extractSongId(mantra.mantraFile);
      }).toList();

      final now = DateTime.now();
      final transactionTime =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

      final amount = widget.totalAmount.toString();
      final currency = widget.currencyCode;

      await SongService.sendPurchaseData(
        transactionId: transactionId,
        transactionTime: transactionTime,
        amount: amount,
        currency: currency,
        songIds: songIds,
      );
    } catch (e) {
      debugPrint('Warning: purchase data sync failed after payment: $e');
    }

    final purchasedItems = List<Mantra>.from(widget.cartItems);
    for (final mantra in purchasedItems) {
      await MantraService.markAsPurchased(mantra);
    }

    await MantraService.clearCart();
    await NotificationService.refresh();

    if (mounted && context.mounted) {
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Payment successful! Your purchase is complete.'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  void _goToCardDetails() {
    setState(() {
      _phase = _PaymentPhase.cardDetails;
      _errorMessage = null;
    });
  }

  Future<void> _handleCardPayment() async {
    setState(() {
      _isLoading = true;
      _busyAction = 'card';
      _errorMessage = null;
    });

    try {
      await _validateCartAndUser();
      final ctx = await _orderContext();

      if (!_cardDetailsComplete) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _busyAction = null;
            _errorMessage = 'Please enter complete card details.';
          });
        }
        return;
      }

      await _ensurePaymentIntentForCard();
      final secret = _clientSecret;
      if (secret == null) {
        throw Exception('Payment not initialized. Please try again.');
      }

      PaymentIntent pi = await Stripe.instance.confirmPayment(
        paymentIntentClientSecret: secret,
        data: PaymentMethodParams.card(
          paymentMethodData: PaymentMethodData(
            billingDetails: BillingDetails(email: ctx.customerEmail),
          ),
        ),
      );

      if (pi.status == PaymentIntentsStatus.RequiresAction) {
        pi = await Stripe.instance.handleNextAction(
          secret,
          returnURL: 'mantrasutra://payment',
        );
      }

      if (pi.status != PaymentIntentsStatus.Succeeded &&
          pi.status != PaymentIntentsStatus.Processing) {
        throw Exception(
          pi.status == PaymentIntentsStatus.Canceled
              ? 'Payment was canceled.'
              : 'Payment could not be completed. Please try again.',
        );
      }

      await _verifyCardOnBackendThenFinish();

      if (mounted) {
        setState(() {
          _isLoading = false;
          _busyAction = null;
        });
      }
    } on StripeException catch (e) {
      if (e.error.code == FailureCode.Canceled) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _busyAction = null;
            _errorMessage = null;
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _isLoading = false;
          _busyAction = null;
          _errorMessage = e.error.message ?? 'Payment failed. Please try again.';
        });
      }
    } catch (e, stackTrace) {
      debugPrint('Payment error: $e\n$stackTrace');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _busyAction = null;
          _errorMessage = 'Payment failed: ${e.toString()}';
        });
      }
    }
  }

  /// One line item per cart unit: song id, display name, amount in smallest currency unit (e.g. cents).
  List<Map<String, dynamic>> _checkoutProducts() {
    final out = <Map<String, dynamic>>[];
    for (final m in widget.cartItems) {
      final productId = SongService.extractSongId(m.mantraFile);
      if (productId.isEmpty) continue;
      final productName = m.name.trim().isNotEmpty ? m.name : productId;
      final unitAmount = (m.price * 100).round();
      out.add({
        'productId': productId,
        'productName': productName,
        'unitAmount': unitAmount,
      });
    }
    return out;
  }

  int get _checkoutUnitCount => widget.cartItems.length;

  Future<void> _handleUpiCheckout() async {
    setState(() {
      _isLoading = true;
      _busyAction = 'upi';
      _errorMessage = null;
    });

    try {
      await _validateCartAndUser();

      final products = _checkoutProducts();
      if (products.isEmpty) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _busyAction = null;
            _errorMessage =
                'No valid items to checkout. Each item needs a song id and price.';
          });
        }
        return;
      }

      final session = await PaymentService.createCheckoutSession(
        currency: widget.currencyCode,
        products: products,
      );

      if (session == null) {
        throw Exception('Could not start UPI checkout');
      }

      final checkoutUrl = _stringFrom(session, [
        'checkoutUrl',
        'checkout_url',
        'url',
      ]);
      final checkoutSessionId = _stringFrom(session, [
        'checkoutSessionId',
        'checkout_session_id',
        'sessionId',
        'session_id',
      ]);

      if (checkoutUrl == null || checkoutSessionId == null) {
        throw Exception('Invalid checkout session response from server');
      }

      final orderId = _stringFrom(session, [
            'orderId',
            'order_id',
          ]) ??
          checkoutSessionId;

      if (mounted) {
        setState(() {
          _isLoading = false;
          _busyAction = null;
        });
      }

      if (!mounted) return;

      final result = await Navigator.of(context).push<StripeCheckoutWebViewResult>(
        MaterialPageRoute(
          builder: (context) => StripeCheckoutWebViewScreen(
            checkoutUrl: checkoutUrl,
            checkoutSessionId: checkoutSessionId,
          ),
        ),
      );

      if (!mounted) return;

      if (result == null || result.cancelled || !result.completedRedirect) {
        return;
      }

      final sessionIdForVerify =
          result.sessionIdForVerify ?? checkoutSessionId;

      setState(() {
        _isLoading = true;
        _busyAction = 'verify';
        _errorMessage = null;
      });

      final outcome = await PaymentService.verifyCheckoutSessionUntilPaid(
        sessionId: sessionIdForVerify,
      );

      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _busyAction = null;
      });

      if (outcome != CheckoutSessionVerifyOutcome.paid) {
        final msg = switch (outcome) {
          CheckoutSessionVerifyOutcome.timeout =>
            'Payment is still processing. If you were charged, your purchase will appear shortly.',
          CheckoutSessionVerifyOutcome.pending =>
            'Payment is still processing. Please check again in a moment.',
          CheckoutSessionVerifyOutcome.failed =>
            'Payment was not completed.',
          CheckoutSessionVerifyOutcome.unpaid =>
            'Payment was not completed.',
          _ => 'Could not confirm payment with the server.',
        };
        setState(() {
          _errorMessage = msg;
        });
        return;
      }

      setState(() {
        _isLoading = true;
        _busyAction = 'verify';
      });

      await _finalizePurchase(transactionId: orderId);

      if (mounted) {
        setState(() {
          _isLoading = false;
          _busyAction = null;
        });
      }
    } catch (e, stackTrace) {
      debugPrint('UPI checkout error: $e\n$stackTrace');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _busyAction = null;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final showBlockingLoader = !_paymentScreenReady && _isLoading;

    final canSubmitCard = _paymentScreenReady &&
        !_isLoading &&
        _cardDetailsComplete &&
        _phase == _PaymentPhase.cardDetails;

    final bool canPopRoute =
        _phase == _PaymentPhase.selectMethod || !_isInr;

    return PopScope(
      canPop: canPopRoute,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_isInr && _phase == _PaymentPhase.cardDetails) {
          setState(() {
            _phase = _PaymentPhase.selectMethod;
            _errorMessage = null;
          });
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text(
            _phase == _PaymentPhase.cardDetails
                ? 'Card payment'
                : 'Payment',
          ),
          backgroundColor: AppColors.primarySaffron,
          foregroundColor: Colors.white,
        ),
        body: showBlockingLoader
            ? const Center(
                child: CircularProgressIndicator(),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _orderSummaryBlock(),
                    if (_phase == _PaymentPhase.selectMethod && _isInr) ...[
                      const SizedBox(height: 28),
                      Text(
                        'Choose payment method',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Payments are processed securely by Stripe.',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (_errorMessage != null) _errorBox(),
                      ElevatedButton(
                        onPressed: _isLoading ? null : _handleUpiCheckout,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isLoading
                              ? Colors.grey
                              : AppColors.primarySaffron,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _isLoading &&
                                (_busyAction == 'upi' ||
                                    _busyAction == 'verify')
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              )
                            : Text(
                                'Pay with UPI $_formattedAmountDisplay',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: _isLoading ? null : _goToCardDetails,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isLoading
                              ? Colors.grey
                              : AppColors.primarySaffron,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          'Pay with Card $_formattedAmountDisplay',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                    if (_phase == _PaymentPhase.cardDetails) ...[
                      const SizedBox(height: 24),
                      Text(
                        'Secure payment',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Enter your card details below. Payments are processed securely by Stripe.',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (_errorMessage != null) _errorBox(),
                      Text(
                        'Card Details',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Material(
                        color: AppColors.white,
                        borderRadius: BorderRadius.circular(12),
                        clipBehavior: Clip.antiAlias,
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: AppColors.textSecondary
                                  .withValues(alpha: 0.25),
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: CardFormField(
                            controller: _cardFormController,
                            autofocus: false,
                            enablePostalCode: true,
                            countryCode: _isInr ? 'IN' : null,
                            style: CardFormStyle(
                              borderColor: Colors.grey.shade300,
                              borderWidth: 0,
                              borderRadius: 8,
                              textColor: AppColors.textPrimary,
                              fontSize: 16,
                              placeholderColor: AppColors.textSecondary,
                            ),
                            onCardChanged: (details) {
                              final complete = details?.complete ?? false;
                              if (complete != _cardDetailsComplete) {
                                setState(() => _cardDetailsComplete = complete);
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: (_isLoading || !canSubmitCard)
                            ? null
                            : _handleCardPayment,
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              (_isLoading || !canSubmitCard)
                                  ? Colors.grey
                                  : AppColors.primarySaffron,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _isLoading && _busyAction == 'card'
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              )
                            : Text(
                                'Pay $_formattedAmountDisplay',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  Widget _orderSummaryBlock() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primarySaffron.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Order Summary',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$_checkoutUnitCount item${_checkoutUnitCount != 1 ? 's' : ''}',
            style: TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Total:',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              Text(
                _formattedAmountDisplay,
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
    );
  }

  Widget _errorBox() {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.1),
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
    );
  }
}


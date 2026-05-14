import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Result after closing Stripe Checkout in a WebView (UPI flow — not PaymentSheet).
class StripeCheckoutWebViewResult {
  final bool cancelled;
  final bool completedRedirect;
  final String? sessionIdForVerify;

  const StripeCheckoutWebViewResult({
    this.cancelled = false,
    this.completedRedirect = false,
    this.sessionIdForVerify,
  });
}

/// Opens [checkoutUrl] (Stripe Checkout). On success redirect, pops with a session id for
/// [PaymentService.verifyCheckoutSession]. Backend should use a `success_url` that either
/// includes Stripe’s `session_id` query param or returns to a non-Stripe https URL after checkout.
class StripeCheckoutWebViewScreen extends StatefulWidget {
  final String checkoutUrl;
  final String checkoutSessionId;

  const StripeCheckoutWebViewScreen({
    super.key,
    required this.checkoutUrl,
    required this.checkoutSessionId,
  });

  @override
  State<StripeCheckoutWebViewScreen> createState() =>
      _StripeCheckoutWebViewScreenState();
}

class _StripeCheckoutWebViewScreenState
    extends State<StripeCheckoutWebViewScreen> {
  late final WebViewController _controller;
  bool _sawStripeCheckoutHost = false;
  bool _finished = false;

  bool _isStripeHosted(String host) {
    final h = host.toLowerCase();
    return h.contains('stripe.com');
  }

  void _completeIfNeeded({required String sessionIdForVerify}) {
    if (_finished || !mounted) return;
    _finished = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop(
        StripeCheckoutWebViewResult(
          completedRedirect: true,
          sessionIdForVerify: sessionIdForVerify,
        ),
      );
    });
  }

  @override
  void initState() {
    super.initState();
    final initial = Uri.tryParse(widget.checkoutUrl);
    _sawStripeCheckoutHost =
        initial != null && _isStripeHosted(initial.host);

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            final uri = Uri.tryParse(url);
            if (uri != null && _isStripeHosted(uri.host)) {
              _sawStripeCheckoutHost = true;
            }
          },
          onNavigationRequest: (NavigationRequest request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.navigate;

            final fromQuery = uri.queryParameters['session_id']?.trim();
            if (fromQuery != null && fromQuery.isNotEmpty) {
              _completeIfNeeded(sessionIdForVerify: fromQuery);
              return NavigationDecision.prevent;
            }

            final host = uri.host.toLowerCase();
            final onStripe = _isStripeHosted(host);
            final leftStripeFlow = _sawStripeCheckoutHost &&
                !onStripe &&
                (uri.scheme == 'https' ||
                    uri.scheme == 'http' ||
                    uri.scheme == 'mantrasutra');
            if (leftStripeFlow) {
              _completeIfNeeded(
                sessionIdForVerify: widget.checkoutSessionId,
              );
              return NavigationDecision.prevent;
            }

            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.checkoutUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Secure checkout'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            if (_finished || !mounted) return;
            _finished = true;
            Navigator.of(context).pop(
              const StripeCheckoutWebViewResult(cancelled: true),
            );
          },
        ),
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../security/stripe_checkout_url_policy.dart';

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

/// Application-owned Stripe Checkout surface.
///
/// Stripe Checkout requires JavaScript. No JavaScript channels or native
/// objects are exposed, and all top-level navigation is denied unless allowed
/// by [StripeCheckoutUrlPolicy].
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
  static const StripeCheckoutUrlPolicy _urlPolicy = StripeCheckoutUrlPolicy();

  late final WebViewController _controller;
  bool _finished = false;
  bool _ready = false;
  String? _errorMessage;

  void _finish(StripeCheckoutWebViewResult result) {
    if (_finished || !mounted) return;
    _finished = true;
    Navigator.of(context).pop(result);
  }

  NavigationDecision _handleNavigation(NavigationRequest request) {
    final callback = _urlPolicy.classifyCallbackUrl(request.url);
    if (_finished) return NavigationDecision.prevent;

    switch (callback.type) {
      case StripeCheckoutCallbackType.success:
        // Bind the callback to the session created for this authenticated flow.
        // The caller still asks the backend to verify authoritative paid state.
        if (callback.sessionId == widget.checkoutSessionId) {
          _finish(
            StripeCheckoutWebViewResult(
              completedRedirect: true,
              sessionIdForVerify: widget.checkoutSessionId,
            ),
          );
        } else {
          setState(() {
            _errorMessage = 'The checkout response could not be validated.';
          });
        }
        return NavigationDecision.prevent;
      case StripeCheckoutCallbackType.cancel:
        _finish(const StripeCheckoutWebViewResult(cancelled: true));
        return NavigationDecision.prevent;
      case StripeCheckoutCallbackType.none:
        break;
    }

    if (_urlPolicy.isAllowedStripeNavigation(request.url)) {
      return NavigationDecision.navigate;
    }

    // mailto:, tel:, arbitrary custom schemes and unknown HTTPS hosts are
    // intentionally rejected. This checkout has no documented need to launch
    // them externally.
    return NavigationDecision.prevent;
  }

  Future<void> _configureAndLoad(Uri initialUrl) async {
    final platformController = _controller.platform;
    if (platformController is AndroidWebViewController) {
      await AndroidWebViewController.enableDebugging(false);
      await platformController.setAllowFileAccess(false);
      await platformController.setAllowContentAccess(false);
      await platformController.setGeolocationEnabled(false);
      await platformController.setMediaPlaybackRequiresUserGesture(true);
      await platformController.setMixedContentMode(MixedContentMode.neverAllow);
      await platformController.setOnShowFileSelector((_) async => <String>[]);
    } else if (platformController is WebKitWebViewController) {
      await platformController.setInspectable(false);
      await platformController.setAllowsLinkPreview(false);
      await platformController.setAllowsBackForwardNavigationGestures(false);
    }

    if (!mounted || _finished) return;
    await _controller.loadRequest(initialUrl);
    if (!mounted) return;
    setState(() {
      _ready = true;
    });
  }

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      // Required by Stripe Checkout; no JavaScript channel is registered.
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _handleNavigation,
          onWebResourceError: (error) {
            if (error.isForMainFrame != true || !mounted || _finished) return;
            setState(() {
              _errorMessage = 'Secure checkout could not be loaded.';
            });
          },
        ),
      );

    final initialUrl = _urlPolicy.validateInitialCheckoutUrl(
      widget.checkoutUrl,
    );

    if (initialUrl == null ||
        !_urlPolicy.validateSessionId(widget.checkoutSessionId)) {
      _errorMessage = 'The checkout link returned by the server is invalid.';
      return;
    }

    unawaited(_configureAndLoad(initialUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Secure checkout'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            _finish(const StripeCheckoutWebViewResult(cancelled: true));
          },
        ),
      ),
      body: _errorMessage != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_errorMessage!, textAlign: TextAlign.center),
              ),
            )
          : Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (!_ready) const Center(child: CircularProgressIndicator()),
              ],
            ),
    );
  }
}

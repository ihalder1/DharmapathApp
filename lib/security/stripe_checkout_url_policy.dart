enum StripeCheckoutCallbackType { none, success, cancel }

enum StripeCheckoutNavigationAction { allow, block }

final class StripeCheckoutNavigationDecision {
  const StripeCheckoutNavigationDecision({
    required this.action,
    required this.reason,
    required this.matchedPolicyRule,
  });

  final StripeCheckoutNavigationAction action;
  final String reason;
  final String matchedPolicyRule;

  bool get isAllowed => action == StripeCheckoutNavigationAction.allow;
}

final class StripeCheckoutCallback {
  const StripeCheckoutCallback._(this.type, this.sessionId);

  const StripeCheckoutCallback.none()
    : this._(StripeCheckoutCallbackType.none, null);

  const StripeCheckoutCallback.cancel()
    : this._(StripeCheckoutCallbackType.cancel, null);

  const StripeCheckoutCallback.success(String sessionId)
    : this._(StripeCheckoutCallbackType.success, sessionId);

  final StripeCheckoutCallbackType type;
  final String? sessionId;
}

/// Strict top-level navigation policy for the application-owned Stripe
/// Checkout WebView.
final class StripeCheckoutUrlPolicy {
  const StripeCheckoutUrlPolicy();

  /// Exact hosts approved for top-level Checkout navigation and redirects.
  static const Set<String> allowedMainFrameStripeHosts = <String>{
    'checkout.stripe.com',
    // Stripe uses this exact host for hosted redirect/return handling.
    'hooks.stripe.com',
    'payments.stripe.com',
    'pm-redirects.stripe.com',
  };

  /// Exact hosts approved inside Stripe Checkout frames.
  ///
  /// `js.stripe.com` serves Stripe's hosted lightbox/UPI UI. It is deliberately
  /// not approved for top-level navigation.
  static const Set<String> allowedSubframeStripeHosts = <String>{
    ...allowedMainFrameStripeHosts,
    'js.stripe.com',
  };

  static const String callbackScheme = 'mantrasutra';
  static const String callbackHost = 'payment';
  static const String httpsCallbackScheme = 'https';
  static const String httpsCallbackHost = 'dharmapath.app';
  static const String successPath = '/success';
  static const String cancelPath = '/cancel';

  Uri? validateInitialCheckoutUrl(String value) {
    final uri = _parse(value);

    return uri != null &&
            uri.host.toLowerCase() == 'checkout.stripe.com' &&
            _isSecureWebUri(uri)
        ? uri
        : null;
  }

  bool isAllowedStripeNavigation(String value) {
    return decideNavigation(value, isMainFrame: true).isAllowed;
  }

  StripeCheckoutNavigationDecision decideNavigation(
    String value, {
    required bool isMainFrame,
  }) {
    final uri = _parse(value);
    if (uri == null) {
      return const StripeCheckoutNavigationDecision(
        action: StripeCheckoutNavigationAction.block,
        reason: 'invalid_url',
        matchedPolicyRule: 'valid_absolute_url_required',
      );
    }
    if (!_isSecureWebUri(uri)) {
      return StripeCheckoutNavigationDecision(
        action: StripeCheckoutNavigationAction.block,
        reason: 'insecure_or_unsupported_url',
        matchedPolicyRule: isMainFrame
            ? 'main_frame_https_only'
            : 'subframe_https_only',
      );
    }

    final host = uri.host.toLowerCase();
    final approvedHosts = isMainFrame
        ? allowedMainFrameStripeHosts
        : allowedSubframeStripeHosts;
    if (approvedHosts.contains(host)) {
      return StripeCheckoutNavigationDecision(
        action: StripeCheckoutNavigationAction.allow,
        reason: isMainFrame
            ? 'approved_stripe_main_frame_host'
            : 'approved_stripe_subframe_host',
        matchedPolicyRule: isMainFrame
            ? 'exact_main_frame_stripe_host'
            : 'exact_subframe_stripe_host',
      );
    }

    return StripeCheckoutNavigationDecision(
      action: StripeCheckoutNavigationAction.block,
      reason: isMainFrame
          ? 'non_stripe_main_frame_host'
          : 'non_stripe_subframe_host',
      matchedPolicyRule: isMainFrame
          ? 'main_frame_host_not_allowlisted'
          : 'subframe_host_not_allowlisted',
    );
  }

  StripeCheckoutCallback classifyCallbackUrl(String value) {
    final uri = _parse(value);
    if (uri == null || uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty) {
      return const StripeCheckoutCallback.none();
    }

    final isCustomCallback =
        uri.scheme.toLowerCase() == callbackScheme &&
        uri.host.toLowerCase() == callbackHost &&
        !uri.hasPort;
    if (isCustomCallback && uri.path == cancelPath) {
      return const StripeCheckoutCallback.cancel();
    }

    final isCustomSuccess = isCustomCallback && uri.path == successPath;
    final isHttpsSuccess =
        uri.scheme == httpsCallbackScheme &&
        uri.host == httpsCallbackHost &&
        uri.path == '/payment/success' &&
        (!uri.hasPort || uri.port == 443);
    if (!isCustomSuccess && !isHttpsSuccess) {
      return const StripeCheckoutCallback.none();
    }

    final sessionIds = uri.queryParametersAll['session_id'];
    if (sessionIds == null || sessionIds.length != 1) {
      return const StripeCheckoutCallback.none();
    }
    final sessionId = sessionIds.single;
    return validateSessionId(sessionId)
        ? StripeCheckoutCallback.success(sessionId)
        : const StripeCheckoutCallback.none();
  }

  bool validateSessionId(String value) {
    if (value.length < 8 || value.length > 255) return false;
    return RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
  }

  static Uri? _parse(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return null;

    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
      return null;
    }

    return uri;
  }

  static bool _isSecureWebUri(Uri uri) {
    return uri.scheme.toLowerCase() == 'https' &&
        uri.userInfo.isEmpty &&
        (!uri.hasPort || uri.port == 443) &&
        !_isRawIpAddress(uri.host);
  }

  static bool _isRawIpAddress(String host) {
    if (host.contains(':')) return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every((part) {
      final value = int.tryParse(part);
      return value != null && value >= 0 && value <= 255;
    });
  }
}

import 'package:flutter/material.dart';

import '../screens/voice_processing_consent_screen.dart';
import '../services/voice_consent_service.dart';

class VoiceConsentGate extends StatefulWidget {
  const VoiceConsentGate({
    super.key,
    required this.userId,
    required this.child,
    this.manager,
  });

  final String userId;
  final Widget child;
  final VoiceConsentManager? manager;

  @override
  State<VoiceConsentGate> createState() => _VoiceConsentGateState();
}

class _VoiceConsentGateState extends State<VoiceConsentGate> {
  late final VoiceConsentManager _manager;
  bool? _hasConsent;

  @override
  void initState() {
    super.initState();
    _manager = widget.manager ?? VoiceConsentService();
    _checkConsent();
  }

  @override
  void didUpdateWidget(covariant VoiceConsentGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) {
      _hasConsent = null;
      _checkConsent();
    }
  }

  Future<void> _checkConsent() async {
    final checkedUserId = widget.userId;
    final hasConsent = await _manager.hasCurrentConsent(checkedUserId);
    if (!mounted || checkedUserId != widget.userId) return;
    setState(() {
      _hasConsent = hasConsent;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_hasConsent == true) return widget.child;
    if (_hasConsent == null) {
      return const PopScope(
        canPop: false,
        child: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return VoiceProcessingConsentScreen(
      userId: widget.userId,
      manager: _manager,
      onAccepted: () {
        if (!mounted) return;
        setState(() {
          _hasConsent = true;
        });
      },
    );
  }
}

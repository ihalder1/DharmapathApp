import 'package:flutter/material.dart';

import '../services/voice_consent_service.dart';

class VoiceProcessingConsentScreen extends StatefulWidget {
  const VoiceProcessingConsentScreen({
    super.key,
    required this.userId,
    required this.manager,
    required this.onAccepted,
  });

  final String userId;
  final VoiceConsentManager manager;
  final VoidCallback onAccepted;

  @override
  State<VoiceProcessingConsentScreen> createState() =>
      _VoiceProcessingConsentScreenState();
}

class _VoiceProcessingConsentScreenState
    extends State<VoiceProcessingConsentScreen> {
  static const String _failureMessage =
      'Unable to record your consent. Please check your connection and try again.';
  static const String _declinedMessage =
      'Voice processing consent is required to use this application.';

  bool _submitting = false;
  String? _message;

  Future<void> _submit(VoiceConsentDecision decision) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _message = null;
    });

    final result = await widget.manager.submit(
      userId: widget.userId,
      decision: decision,
    );
    if (!mounted) return;

    if (result != VoiceConsentSubmissionResult.success) {
      setState(() {
        _submitting = false;
        _message = _failureMessage;
      });
      return;
    }

    if (decision == VoiceConsentDecision.agree) {
      widget.onAccepted();
      return;
    }

    setState(() {
      _submitting = false;
      _message = _declinedMessage;
    });
  }

  @override
  Widget build(BuildContext context) {
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final isDark = platformBrightness == Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: Theme.of(context).colorScheme.primary,
      brightness: platformBrightness,
    );

    return PopScope(
      canPop: false,
      child: Theme(
        data: Theme.of(context).copyWith(colorScheme: colorScheme),
        child: Builder(
          builder: (context) {
            return Scaffold(
              backgroundColor: isDark
                  ? colorScheme.surface
                  : Theme.of(context).scaffoldBackgroundColor,
              body: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Card(
                        color: colorScheme.surfaceContainerHighest,
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Icon(
                                Icons.graphic_eq,
                                size: 52,
                                color: colorScheme.primary,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Voice Processing Consent',
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(
                                      color: colorScheme.onSurface,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                              const SizedBox(height: 20),
                              Text(
                                'To provide voice conversion features, your audio is processed through secure, encrypted cloud networks.',
                                style: TextStyle(color: colorScheme.onSurface),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Temporary Processing:',
                                style: TextStyle(
                                  color: colorScheme.onSurface,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Audio files are processed only to perform your requested voice conversion and are deleted after processing. Your voice recordings are not retained for future use.',
                                style: TextStyle(color: colorScheme.onSurface),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Data Privacy:',
                                style: TextStyle(
                                  color: colorScheme.onSurface,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Your recordings are encrypted during transmission and are never shared with third parties or used to train public AI models.',
                                style: TextStyle(color: colorScheme.onSurface),
                              ),
                              if (_message != null) ...[
                                const SizedBox(height: 20),
                                Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    _message!,
                                    key: const Key('voice-consent-message'),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: colorScheme.error,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 24),
                              if (_submitting)
                                const Center(child: CircularProgressIndicator())
                              else
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton(
                                        key: const Key('voice-consent-decline'),
                                        onPressed: () => _submit(
                                          VoiceConsentDecision.disagree,
                                        ),
                                        child: const Text('Decline'),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: ElevatedButton(
                                        key: const Key('voice-consent-agree'),
                                        onPressed: () =>
                                            _submit(VoiceConsentDecision.agree),
                                        child: const Text('I Agree'),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

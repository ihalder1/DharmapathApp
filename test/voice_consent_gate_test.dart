import 'package:colab_app_ui/services/voice_consent_service.dart';
import 'package:colab_app_ui/widgets/voice_consent_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class FakeConsentManager implements VoiceConsentManager {
  FakeConsentManager({this.hasConsent = false, this.submitSucceeds = true});

  bool hasConsent;
  bool submitSucceeds;
  VoiceConsentDecision? lastDecision;

  @override
  Future<bool> hasCurrentConsent(String userId) async => hasConsent;

  @override
  Future<VoiceConsentSubmissionResult> submit({
    required String userId,
    required VoiceConsentDecision decision,
  }) async {
    lastDecision = decision;
    if (!submitSucceeds) return VoiceConsentSubmissionResult.failure;
    if (decision == VoiceConsentDecision.agree) hasConsent = true;
    return VoiceConsentSubmissionResult.success;
  }
}

Widget buildGate(FakeConsentManager manager) {
  return MaterialApp(
    home: VoiceConsentGate(
      userId: 'user-123',
      manager: manager,
      child: const Scaffold(body: Text('Application Home')),
    ),
  );
}

void main() {
  testWidgets('first login shows the mandatory consent screen', (tester) async {
    await tester.pumpWidget(buildGate(FakeConsentManager()));
    await tester.pumpAndSettle();

    expect(find.text('Voice Processing Consent'), findsOneWidget);
    expect(find.text('Application Home'), findsNothing);
  });

  testWidgets('current consent opens the application', (tester) async {
    await tester.pumpWidget(buildGate(FakeConsentManager(hasConsent: true)));
    await tester.pumpAndSettle();

    expect(find.text('Application Home'), findsOneWidget);
    expect(find.text('Voice Processing Consent'), findsNothing);
  });

  testWidgets('agree opens the application only after success', (tester) async {
    final manager = FakeConsentManager();
    await tester.pumpWidget(buildGate(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('voice-consent-agree')));
    await tester.pumpAndSettle();

    expect(manager.lastDecision, VoiceConsentDecision.agree);
    expect(find.text('Application Home'), findsOneWidget);
  });

  testWidgets('offline agree keeps the application blocked', (tester) async {
    final manager = FakeConsentManager(submitSucceeds: false);
    await tester.pumpWidget(buildGate(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('voice-consent-agree')));
    await tester.pumpAndSettle();

    expect(find.text('Application Home'), findsNothing);
    expect(
      find.text(
        'Unable to record your consent. Please check your connection and try again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('decline records the choice but remains blocked', (tester) async {
    final manager = FakeConsentManager();
    await tester.pumpWidget(buildGate(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('voice-consent-decline')));
    await tester.pumpAndSettle();

    expect(manager.lastDecision, VoiceConsentDecision.disagree);
    expect(find.text('Application Home'), findsNothing);
    expect(
      find.text(
        'Voice processing consent is required to use this application.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('offline decline remains blocked with retry message', (
    tester,
  ) async {
    final manager = FakeConsentManager(submitSucceeds: false);
    await tester.pumpWidget(buildGate(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('voice-consent-decline')));
    await tester.pumpAndSettle();

    expect(find.text('Application Home'), findsNothing);
    expect(
      find.text(
        'Unable to record your consent. Please check your connection and try again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('system back cannot bypass consent', (tester) async {
    await tester.pumpWidget(buildGate(FakeConsentManager()));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Voice Processing Consent'), findsOneWidget);
    expect(find.text('Application Home'), findsNothing);
  });
}

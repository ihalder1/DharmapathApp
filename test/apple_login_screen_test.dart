import 'dart:async';

import 'package:colab_app_ui/screens/login_screen.dart';
import 'package:colab_app_ui/services/auth_service.dart';
import 'package:colab_app_ui/services/secure_session_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _ScreenAuth extends AuthService {
  _ScreenAuth() : super.forTesting(SecureSessionStorage());

  Future<bool> Function()? action;
  int attempts = 0;

  @override
  Future<bool> signInWithApple() async {
    attempts++;
    return action?.call() ?? true;
  }
}

void main() {
  late _ScreenAuth auth;

  setUp(() {
    auth = _ScreenAuth();
  });

  tearDown(() {
    auth.dispose();
  });

  Future<void> showLogin(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthService>.value(
        value: auth,
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('iOS shows all three providers using the Apple button', (
    tester,
  ) async {
    await showLogin(tester);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Facebook'), findsOneWidget);
    expect(find.text('Continue with Apple'), findsOneWidget);
    expect(
      find.widgetWithText(ElevatedButton, 'Continue with Apple'),
      findsOneWidget,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('Android preserves Google and Facebook without Apple', (
    tester,
  ) async {
    await showLogin(tester);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Facebook'), findsOneWidget);
    expect(
      find.widgetWithText(ElevatedButton, 'Continue with Apple'),
      findsNothing,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('pending Apple authorization disables all login buttons', (
    tester,
  ) async {
    final completion = Completer<bool>();
    auth.action = () => completion.future;
    await showLogin(tester);
    await tester.tap(
      find.widgetWithText(ElevatedButton, 'Continue with Apple'),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Continue with Apple'),
          )
          .onPressed,
      isNull,
    );
    for (final button in tester.widgetList<ElevatedButton>(
      find.byType(ElevatedButton),
    )) {
      expect(button.onPressed, isNull);
    }
    await tester.tap(
      find.widgetWithText(ElevatedButton, 'Continue with Apple'),
    );
    await tester.pump();
    expect(auth.attempts, 1);
    // No UI timeout may reopen buttons while the native sheet remains open.
    await tester.pump(const Duration(seconds: 61));
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Continue with Apple'),
          )
          .onPressed,
      isNull,
    );
    completion.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('cancellation clears loading without an error', (tester) async {
    auth.action = () async => throw const AppleSignInCancelled();
    await showLogin(tester);
    await tester.tap(
      find.widgetWithText(ElevatedButton, 'Continue with Apple'),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Continue with Apple'),
          )
          .onPressed,
      isNotNull,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('unexpected errors never expose credential details', (
    tester,
  ) async {
    auth.action = () async => throw StateError('secret-token-code-nonce');
    await showLogin(tester);
    await tester.tap(
      find.widgetWithText(ElevatedButton, 'Continue with Apple'),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Unable to sign in with Apple. Please try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('secret-token-code-nonce'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:colab_app_ui/main.dart';

void main() {
  testWidgets('App displays its startup state', (WidgetTester tester) async {
    await tester.pumpWidget(const ColabApp());

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}

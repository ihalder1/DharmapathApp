import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _section(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex + start.length);
  expect(startIndex, isNonNegative, reason: 'Missing section start: $start');
  expect(
    endIndex,
    greaterThan(startIndex),
    reason: 'Missing section end: $end',
  );
  return source.substring(startIndex, endIndex);
}

void main() {
  final homeSource = File('lib/screens/home_screen.dart').readAsStringSync();
  final mainSource = File('lib/main.dart').readAsStringSync();
  final loginSource = File('lib/screens/login_screen.dart').readAsStringSync();

  test('the application root owns authentication navigation', () {
    expect(mainSource, contains('home: const AuthWrapper()'));

    final loginSuccessPath = _section(
      loginSource,
      'Future<void> _performSignIn(',
      '\n  }\n}',
    );
    expect(loginSuccessPath, isNot(contains('Navigator.')));
    expect(
      loginSuccessPath,
      contains('AuthWrapper will rebuild and show HomeScreen'),
    );
  });

  test('delete account returns through the existing AuthWrapper', () {
    final deleteHandler = _section(
      homeSource,
      'Future<void> _showDeleteAccountDialog()',
      'void _showLogoutDialog(',
    );

    expect(deleteHandler, contains('clearLocalSessionAfterAccountDeletion()'));
    expect(deleteHandler, contains('Navigator.of(dialogContext).pop()'));
    expect(deleteHandler, isNot(contains('pushAndRemoveUntil')));
    expect(deleteHandler, isNot(contains('const LoginScreen()')));
    expect(deleteHandler, isNot(contains('const HomeScreen()')));
  });

  test('logout returns through the existing AuthWrapper', () {
    final logoutHandler = _section(
      homeSource,
      'void _showLogoutDialog(',
      'void _showCreateMantraDialog(',
    );

    expect(logoutHandler, contains('.logout()'));
    expect(logoutHandler, isNot(contains('pushAndRemoveUntil')));
    expect(logoutHandler, isNot(contains('const LoginScreen()')));
    expect(logoutHandler, isNot(contains('const HomeScreen()')));
  });
}

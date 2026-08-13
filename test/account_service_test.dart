import 'dart:convert';

import 'package:colab_app_ui/constants/api_config.dart';
import 'package:colab_app_ui/services/account_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test(
    'delete account sends the required endpoint and confirmation body',
    () async {
      Uri? requestedUrl;
      Object? requestedBody;
      final service = AccountService(
        deleteRequest: (url, {body}) async {
          requestedUrl = url;
          requestedBody = body;
          return http.Response('', 200);
        },
      );

      expect(await service.deleteAccount(), isTrue);
      expect(
        requestedUrl,
        Uri.parse('${ApiConfig.baseUrl}${ApiConfig.accountEndpoint}'),
      );
      expect(json.decode(requestedBody! as String), const {
        'confirmation': 'DELETE_MY_ACCOUNT',
      });
    },
  );

  test('delete account accepts no-content success', () async {
    final service = AccountService(
      deleteRequest: (_, {body}) async => http.Response('', 204),
    );

    expect(await service.deleteAccount(), isTrue);
  });

  test('delete account reports HTTP and network failures', () async {
    final httpFailure = AccountService(
      deleteRequest: (_, {body}) async => http.Response('', 500),
    );
    final networkFailure = AccountService(
      deleteRequest: (_, {body}) async => throw Exception('offline'),
    );

    expect(await httpFailure.deleteAccount(), isFalse);
    expect(await networkFailure.deleteAccount(), isFalse);
  });
}

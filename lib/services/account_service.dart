import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants/api_config.dart';
import 'authenticated_http.dart';

typedef AccountDeleteRequest =
    Future<http.Response> Function(Uri url, {Object? body});

class AccountService {
  AccountService({AccountDeleteRequest? deleteRequest})
    : _deleteRequest =
          deleteRequest ??
          ((url, {body}) => AuthenticatedHttp.delete(url, body: body));

  final AccountDeleteRequest _deleteRequest;

  Future<bool> deleteAccount() async {
    try {
      final response = await _deleteRequest(
        Uri.parse('${ApiConfig.baseUrl}${ApiConfig.accountEndpoint}'),
        body: json.encode(const {'confirmation': 'DELETE_MY_ACCOUNT'}),
      );
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }
}

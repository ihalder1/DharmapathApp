import 'dart:async';
import 'dart:convert';

import 'package:colab_app_ui/services/auth_service.dart';
import 'package:colab_app_ui/services/secure_session_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  bool failRefreshWrite = false;
  Completer<void>? holdAccessWrite;
  Completer<void>? accessWriteStarted;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (key == SecureSessionStorage.accessTokenKey && holdAccessWrite != null) {
      accessWriteStarted?.complete();
      await holdAccessWrite!.future;
    }
    if (failRefreshWrite && key == SecureSessionStorage.refreshTokenKey) {
      throw StateError('storage unavailable');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

Map<String, dynamic> _session({bool nested = true}) {
  final tokens = <String, dynamic>{
    'accessToken': 'backend-access',
    'refreshToken': 'backend-refresh',
    'expiresIn': 3600,
  };
  return {
    if (nested) 'tokens': tokens else ...tokens,
    'user': {
      'userId': 'backend-user',
      'name': 'Stored Name',
      'email': 'private@privaterelay.appleid.com',
      'photoUrl': 'https://example.invalid/profile.png',
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const appleChannel = MethodChannel(
    'com.aboutyou.dart_packages.sign_in_with_apple',
  );
  const googleChannel = MethodChannel('plugins.flutter.io/google_sign_in');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _MemoryStore store;
  late SecureSessionStorage storage;
  late AuthService auth;
  late Map<String, dynamic> credential;
  late List<Map<dynamic, dynamic>> nativeRequests;
  late List<http.Request> backendRequests;
  String? nativeError;
  Completer<Map<String, dynamic>>? nativeCompletion;
  late int googleCalls;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    SharedPreferences.setMockInitialValues({'device_id': 'existing-device'});
    store = _MemoryStore();
    storage = SecureSessionStorage(store: store);
    auth = AuthService.forTesting(storage);
    credential = {
      'type': 'appleid',
      'userIdentifier': 'apple-subject',
      'identityToken': 'apple-identity-credential',
      'authorizationCode': 'apple-authorization-code',
      'givenName': 'First',
      'familyName': 'Authorization',
      'email': 'native-email-is-not-sent@example.invalid',
    };
    nativeRequests = [];
    backendRequests = [];
    nativeError = null;
    nativeCompletion = null;
    googleCalls = 0;
    messenger.setMockMethodCallHandler(appleChannel, (call) async {
      expect(call.method, 'performAuthorizationRequest');
      nativeRequests.add((call.arguments as List).single as Map);
      if (nativeError != null) {
        throw PlatformException(
          code: nativeError!,
          message: 'sensitive-native-exception-detail',
        );
      }
      if (nativeCompletion != null) return nativeCompletion!.future;
      return credential;
    });
    messenger.setMockMethodCallHandler(googleChannel, (call) async {
      googleCalls++;
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(appleChannel, null);
    messenger.setMockMethodCallHandler(googleChannel, null);
    debugDefaultTargetPlatformOverride = null;
    auth.dispose();
  });

  Future<bool> signIn({int status = 200, String? body, Exception? error}) {
    return http.runWithClient(
      auth.signInWithApple,
      () => MockClient((request) async {
        backendRequests.add(request);
        if (error != null) throw error;
        return http.Response(body ?? jsonEncode(_session()), status);
      }),
    );
  }

  test(
    'native nonce hash and backend request match the exact contract',
    () async {
      var notifications = 0;
      auth.addListener(() => notifications++);
      expect(await signIn(status: 201), isTrue);
      final request = backendRequests.single;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://api-online.mantrasutra.ids-ai.net/v1/auth/apple-signin',
      );
      expect(
        request.headers['Authorization'],
        'Bearer apple-identity-credential',
      );
      expect(request.headers['Content-Type'], startsWith('application/json'));
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body.keys.toSet(), {
        'authorizationCode',
        'rawNonce',
        'user',
        'deviceInfo',
      });
      expect(body['authorizationCode'], 'apple-authorization-code');
      expect(body['user'], {
        'givenName': 'First',
        'familyName': 'Authorization',
      });
      expect(body['deviceInfo'], {
        'platform': 'ios',
        'deviceId': 'existing-device',
        'appVersion': '1.0.0',
      });
      final rawNonce = body['rawNonce'] as String;
      expect(base64Url.decode(base64Url.normalize(rawNonce)), hasLength(32));
      expect(
        nativeRequests.single['nonce'],
        sha256.convert(utf8.encode(rawNonce)).toString(),
      );
      expect(
        nativeRequests.single['nonce'],
        matches(RegExp(r'^[a-f0-9]{64}$')),
      );
      expect(nativeRequests.single['scopes'], ['email', 'fullName']);
      expect(request.body, isNot(contains('apple-identity-credential')));
      expect(request.body, isNot(contains('native-email-is-not-sent')));
      expect(auth.currentUser?.id, 'backend-user');
      expect(auth.currentUser?.name, 'Stored Name');
      expect(auth.currentUser?.email, 'private@privaterelay.appleid.com');
      expect(auth.currentUser?.provider, 'apple');
      expect(auth.accessToken, 'backend-access');
      expect(await storage.readRefreshToken(), 'backend-refresh');
      expect(notifications, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('access_token'), isNull);
      expect(
        DateTime.parse(
          prefs.getString('token_expiry')!,
        ).isAfter(DateTime.now()),
        isTrue,
      );
    },
  );

  test(
    'returning users send JSON null names and preserve backend profile',
    () async {
      credential.remove('givenName');
      credential.remove('familyName');
      credential.remove('email');
      expect(await signIn(), isTrue);
      expect(jsonDecode(backendRequests.single.body)['user'], {
        'givenName': null,
        'familyName': null,
      });
      expect(auth.currentUser?.name, 'Stored Name');
      expect(auth.currentUser?.email, 'private@privaterelay.appleid.com');
      final restored = AuthService.forTesting(storage);
      await restored.restoreSessionForTesting();
      expect(restored.isLoggedIn, isTrue);
      expect(restored.currentUser?.provider, 'apple');
      expect(restored.accessToken, 'backend-access');
      restored.dispose();
    },
  );

  test('root-level Google-compatible session response is supported', () async {
    expect(await signIn(body: jsonEncode(_session(nested: false))), isTrue);
  });

  test('session is not published until secure persistence completes', () async {
    store.holdAccessWrite = Completer<void>();
    store.accessWriteStarted = Completer<void>();
    var notifications = 0;
    auth.addListener(() => notifications++);
    final pending = signIn();
    await store.accessWriteStarted!.future;
    expect(auth.isLoggedIn, isFalse);
    expect(auth.currentUser, isNull);
    expect(notifications, 0);
    store.holdAccessWrite!.complete();
    expect(await pending, isTrue);
    expect(auth.isLoggedIn, isTrue);
    expect(notifications, 1);
  });

  test('Apple sessions use existing refresh and token rotation', () async {
    final response = _session();
    (response['tokens'] as Map)['expiresIn'] = 60;
    expect(await signIn(body: jsonEncode(response)), isTrue);
    final refreshed = await http.runWithClient(
      auth.ensureValidAccessToken,
      () => MockClient((request) async {
        expect(request.url.path, '/v1/auth/refresh');
        expect(request.headers['Authorization'], 'Bearer backend-refresh');
        return http.Response(
          jsonEncode({
            'tokens': {
              'accessToken': 'rotated-access',
              'refreshToken': 'rotated-refresh',
              'expiresIn': 3600,
            },
          }),
          200,
        );
      }),
    );
    expect(refreshed, isTrue);
    expect(auth.accessToken, 'rotated-access');
    expect(await storage.readRefreshToken(), 'rotated-refresh');
    expect(auth.currentUser?.provider, 'apple');
    expect(auth.currentUser?.name, 'Stored Name');
  });

  test('backend profile can omit name and email', () async {
    final response = _session();
    response['user'] = {'id': 'backend-user'};
    expect(await signIn(body: jsonEncode(response)), isTrue);
    expect(auth.currentUser?.name, '');
    expect(auth.currentUser?.email, '');
  });

  test(
    'cancellation makes no backend request and permits a new attempt',
    () async {
      nativeError = 'authorization-error/canceled';
      await expectLater(signIn(), throwsA(isA<AppleSignInCancelled>()));
      expect(backendRequests, isEmpty);
      expect(auth.isLoggedIn, isFalse);
      expect(store.values, isEmpty);
      nativeError = null;
      expect(await signIn(), isTrue);
    },
  );

  test('authorization failure hides native exception details', () async {
    nativeError = 'authorization-error/failed';
    await expectLater(
      signIn(),
      throwsA(
        isA<AppleSignInException>().having(
          (e) => e.message,
          'safe message',
          isNot(contains('sensitive-native')),
        ),
      ),
    );
    expect(backendRequests, isEmpty);
    expect(auth.isLoggedIn, isFalse);
  });

  for (final missing in ['identityToken', 'authorizationCode']) {
    test('missing $missing cannot establish a session', () async {
      credential.remove(missing);
      await expectLater(signIn(), throwsA(isA<AppleSignInException>()));
      expect(backendRequests, isEmpty);
      expect(auth.isLoggedIn, isFalse);
    });
    test('empty $missing cannot establish a session', () async {
      credential[missing] = ' ';
      await expectLater(signIn(), throwsA(isA<AppleSignInException>()));
      expect(backendRequests, isEmpty);
    });
  }

  for (final status in [400, 401, 403, 409, 500]) {
    test(
      'HTTP $status never publishes credentials or backend error text',
      () async {
        await expectLater(
          signIn(status: status, body: 'sensitive-backend-detail'),
          throwsA(
            isA<AppleSignInException>().having(
              (e) => e.message,
              'safe message',
              isNot(contains('sensitive-backend')),
            ),
          ),
        );
        expect(auth.isLoggedIn, isFalse);
        expect(store.values, isEmpty);
      },
    );
  }

  for (final body in ['invalid JSON', 'null', '[]', '{}']) {
    test('invalid session body $body fails without creating a user', () async {
      await expectLater(
        signIn(body: body),
        throwsA(isA<AppleSignInException>()),
      );
      expect(auth.currentUser, isNull);
      expect(store.values, isEmpty);
    });
  }

  for (final missing in ['accessToken', 'refreshToken']) {
    test('missing backend $missing rejects the session', () async {
      final response = _session();
      (response['tokens'] as Map).remove(missing);
      await expectLater(
        signIn(body: jsonEncode(response)),
        throwsA(isA<AppleSignInException>()),
      );
      expect(auth.isLoggedIn, isFalse);
      expect(store.values, isEmpty);
    });
  }

  test('missing backend user ID rejects the session', () async {
    final response = _session();
    (response['user'] as Map).remove('userId');
    await expectLater(
      signIn(body: jsonEncode(response)),
      throwsA(isA<AppleSignInException>()),
    );
    expect(auth.isLoggedIn, isFalse);
    expect(store.values, isEmpty);
  });

  test('malformed expiry rejects the session', () async {
    final response = _session();
    (response['tokens'] as Map)['expiresIn'] = 'invalid';
    await expectLater(
      signIn(body: jsonEncode(response)),
      throwsA(isA<AppleSignInException>()),
    );
    expect(store.values, isEmpty);
  });

  test('network errors and timeouts do not leak exception contents', () async {
    for (final error in [
      http.ClientException('apple-identity-credential'),
      TimeoutException('apple-authorization-code'),
    ]) {
      await expectLater(
        signIn(error: error),
        throwsA(
          isA<AppleSignInException>()
              .having(
                (e) => e.message,
                'safe message',
                isNot(contains('apple-identity-credential')),
              )
              .having(
                (e) => e.message,
                'safe code',
                isNot(contains('apple-authorization-code')),
              ),
        ),
      );
      expect(auth.isLoggedIn, isFalse);
    }
  });

  test(
    'duplicate Apple calls open one native sheet and one backend request',
    () async {
      nativeCompletion = Completer<Map<String, dynamic>>();
      final first = signIn();
      await expectLater(signIn(), throwsA(isA<AppleSignInException>()));
      nativeCompletion!.complete(credential);
      expect(await first, isTrue);
      expect(nativeRequests, hasLength(1));
      expect(backendRequests, hasLength(1));
    },
  );

  test(
    'partial secure write failure leaves no authenticated session',
    () async {
      store.failRefreshWrite = true;
      await expectLater(signIn(), throwsA(isA<AppleSignInException>()));
      expect(auth.isLoggedIn, isFalse);
      expect(auth.currentUser, isNull);
      expect(store.values, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('user_id'), isNull);
      expect(prefs.getString('device_id'), 'existing-device');
    },
  );

  test(
    'Apple logout clears session, skips Google, and allows a fresh nonce',
    () async {
      expect(await signIn(), isTrue);
      final firstNonce = nativeRequests.single['nonce'];
      await http.runWithClient(
        auth.logout,
        () => MockClient((request) async {
          expect(request.url.path, '/v1/auth/logout');
          expect(request.headers['Authorization'], 'Bearer backend-access');
          return http.Response('{}', 200);
        }),
      );
      expect(auth.isLoggedIn, isFalse);
      expect(auth.currentUser, isNull);
      expect(store.values, isEmpty);
      expect(googleCalls, 0);
      expect(
        nativeRequests,
        hasLength(1),
      ); // Ordinary logout never revokes Apple.
      expect(await signIn(), isTrue);
      expect(nativeRequests.last['nonce'], isNot(firstNonce));
    },
  );

  test('Android cannot open Apple authorization or call the backend', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await expectLater(signIn(), throwsA(isA<AppleSignInException>()));
    expect(nativeRequests, isEmpty);
    expect(backendRequests, isEmpty);
  });
}

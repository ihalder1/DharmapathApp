import 'package:colab_app_ui/services/auth_service.dart';
import 'package:colab_app_ui/services/secure_session_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class MemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> values = <String, String>{};
  final Set<String> failingWrites = <String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failingWrites.contains(key)) {
      throw StateError('simulated secure write failure');
    }
    values[key] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android session secrets explicitly use OAEP and AES-GCM', () {
    final options = FlutterSecureKeyValueStore.androidOptions.toMap();

    expect(
      options['keyCipherAlgorithm'],
      'RSA_ECB_OAEPwithSHA_256andMGF1Padding',
    );
    expect(options['storageCipherAlgorithm'], 'AES_GCM_NoPadding');
    expect(options['migrateOnAlgorithmChange'], 'true');
    expect(options['storageNamespace'], 'auth_session');
    expect(options.values, isNot(contains('AES_CBC_PKCS7Padding')));
  });

  late MemorySecureStore secureStore;
  late SecureSessionStorage sessionStorage;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    secureStore = MemorySecureStore();
    sessionStorage = SecureSessionStorage(store: secureStore);
  });

  test('writes access and refresh tokens only to secure storage', () async {
    await sessionStorage.saveAccessToken('access-value');
    await sessionStorage.saveRefreshToken('refresh-value');
    final preferences = await SharedPreferences.getInstance();

    expect(await sessionStorage.readAccessToken(), 'access-value');
    expect(await sessionStorage.readRefreshToken(), 'refresh-value');
    expect(preferences.getString('access_token'), isNull);
    expect(preferences.getString('auth_token'), isNull);
    expect(preferences.getString('refresh_token'), isNull);
    expect(secureStore.values.keys, {
      SecureSessionStorage.accessTokenKey,
      SecureSessionStorage.refreshTokenKey,
    });
  });

  test('migrates legacy tokens and removes plaintext keys', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'access_token': 'legacy-access',
      'auth_token': 'legacy-access-duplicate',
      'refresh_token': 'legacy-refresh',
    });
    final preferences = await SharedPreferences.getInstance();

    final result = await sessionStorage.migrateLegacyTokens(preferences);

    expect(result, LegacyTokenMigrationResult.migrated);
    expect(await sessionStorage.readAccessToken(), 'legacy-access');
    expect(await sessionStorage.readRefreshToken(), 'legacy-refresh');
    expect(preferences.containsKey('access_token'), isFalse);
    expect(preferences.containsKey('auth_token'), isFalse);
    expect(preferences.containsKey('refresh_token'), isFalse);
  });

  test('failed secure write preserves the recoverable legacy value', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'access_token': 'recoverable-access',
    });
    secureStore.failingWrites.add(SecureSessionStorage.accessTokenKey);
    final preferences = await SharedPreferences.getInstance();

    final result = await sessionStorage.migrateLegacyTokens(preferences);

    expect(result, LegacyTokenMigrationResult.failed);
    expect(preferences.getString('access_token'), 'recoverable-access');
    expect(await sessionStorage.readAccessToken(), isNull);
  });

  test('clearing a session removes secure and legacy token keys', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'access_token': 'legacy-access',
      'auth_token': 'legacy-duplicate',
      'refresh_token': 'legacy-refresh',
      'onboarding_complete': true,
    });
    final preferences = await SharedPreferences.getInstance();
    await sessionStorage.saveAccessToken('secure-access');
    await sessionStorage.saveRefreshToken('secure-refresh');

    await sessionStorage.clearSessionSecrets();
    await SecureSessionStorage.removeLegacyTokenKeys(preferences);

    expect(await sessionStorage.readAccessToken(), isNull);
    expect(await sessionStorage.readRefreshToken(), isNull);
    expect(preferences.containsKey('access_token'), isFalse);
    expect(preferences.containsKey('auth_token'), isFalse);
    expect(preferences.containsKey('refresh_token'), isFalse);
    expect(preferences.getBool('onboarding_complete'), isTrue);
  });

  test('AuthService restores tokens from secure storage', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'user_id': 'user-1',
      'user_name': 'Test User',
      'user_email': 'test@example.invalid',
      'user_provider': 'google',
      'token_expiry': DateTime.now()
          .add(const Duration(hours: 1))
          .toIso8601String(),
    });
    await sessionStorage.saveAccessToken('secure-access');
    await sessionStorage.saveRefreshToken('secure-refresh');
    final auth = AuthService.forTesting(sessionStorage);

    await auth.restoreSessionForTesting();

    expect(auth.accessToken, 'secure-access');
    expect(auth.currentUser?.id, 'user-1');
    expect(auth.isLoggedIn, isTrue);
  });

  test(
    'session save and token update replace the canonical secure values',
    () async {
      final auth = AuthService.forTesting(sessionStorage);
      final user = User(
        id: 'user-1',
        name: 'Test User',
        email: 'test@example.invalid',
        provider: 'google',
      );

      await auth.persistSessionForTesting(
        user: user,
        accessToken: 'initial-access',
        refreshToken: 'initial-refresh',
      );
      await auth.persistSessionForTesting(
        user: user,
        accessToken: 'refreshed-access',
        refreshToken: 'rotated-refresh',
      );
      final preferences = await SharedPreferences.getInstance();

      expect(await sessionStorage.readAccessToken(), 'refreshed-access');
      expect(await sessionStorage.readRefreshToken(), 'rotated-refresh');
      expect(secureStore.values.keys, {
        SecureSessionStorage.accessTokenKey,
        SecureSessionStorage.refreshTokenKey,
      });
      expect(preferences.containsKey('access_token'), isFalse);
      expect(preferences.containsKey('auth_token'), isFalse);
      expect(preferences.containsKey('refresh_token'), isFalse);
    },
  );
}

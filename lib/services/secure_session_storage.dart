import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  FlutterSecureKeyValueStore([FlutterSecureStorage? storage])
    : _storage = storage ?? _configuredStorage;

  /// Explicit Android policy for all application-owned session secrets.
  ///
  /// Keeping this public allows regression tests to verify that fresh writes
  /// cannot silently fall back to the plugin's legacy CBC compatibility mode.
  static const AndroidOptions androidOptions = AndroidOptions(
    resetOnError: false,
    migrateOnAlgorithmChange: true,
    migrateWithBackup: false,
    keyCipherAlgorithm:
        KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
    storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
    storageNamespace: 'auth_session',
  );

  static const FlutterSecureStorage _configuredStorage = FlutterSecureStorage(
    aOptions: androidOptions,
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
      accountName: 'com.colab.auth.session',
    ),
  );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

enum LegacyTokenMigrationResult { notNeeded, migrated, failed }

final class SecureSessionStorage {
  SecureSessionStorage({SecureKeyValueStore? store})
    : _store = store ?? FlutterSecureKeyValueStore();

  static const String accessTokenKey = 'auth_access_token';
  static const String refreshTokenKey = 'auth_refresh_token';

  static const String legacyAccessTokenKey = 'access_token';
  static const String legacyDuplicateAccessTokenKey = 'auth_token';
  static const String legacyRefreshTokenKey = 'refresh_token';

  final SecureKeyValueStore _store;

  Future<void> saveAccessToken(String token) =>
      _writeAndVerify(accessTokenKey, token);

  Future<String?> readAccessToken() => _store.read(accessTokenKey);

  Future<void> saveRefreshToken(String token) =>
      _writeAndVerify(refreshTokenKey, token);

  Future<String?> readRefreshToken() => _store.read(refreshTokenKey);

  Future<void> deleteAccessToken() => _store.delete(accessTokenKey);

  Future<void> deleteRefreshToken() => _store.delete(refreshTokenKey);

  Future<void> clearSessionSecrets() async {
    await deleteAccessToken();
    await deleteRefreshToken();
  }

  /// Migrates legacy plaintext tokens without deleting the only recoverable
  /// copy until the secure write has been verified by reading it back.
  Future<LegacyTokenMigrationResult> migrateLegacyTokens(
    SharedPreferences preferences,
  ) async {
    var migrated = false;
    try {
      var secureAccessToken = await readAccessToken();
      final legacyAccessToken = _firstNonEmpty([
        preferences.getString(legacyAccessTokenKey),
        preferences.getString(legacyDuplicateAccessTokenKey),
      ]);

      if (_isEmpty(secureAccessToken) && !_isEmpty(legacyAccessToken)) {
        await saveAccessToken(legacyAccessToken!);
        secureAccessToken = legacyAccessToken;
        migrated = true;
      }
      if (!_isEmpty(secureAccessToken)) {
        await preferences.remove(legacyAccessTokenKey);
        await preferences.remove(legacyDuplicateAccessTokenKey);
      }

      var secureRefreshToken = await readRefreshToken();
      final legacyRefreshToken = preferences.getString(legacyRefreshTokenKey);
      if (_isEmpty(secureRefreshToken) && !_isEmpty(legacyRefreshToken)) {
        await saveRefreshToken(legacyRefreshToken!);
        secureRefreshToken = legacyRefreshToken;
        migrated = true;
      }
      if (!_isEmpty(secureRefreshToken)) {
        await preferences.remove(legacyRefreshTokenKey);
      }

      return migrated
          ? LegacyTokenMigrationResult.migrated
          : LegacyTokenMigrationResult.notNeeded;
    } catch (_) {
      return LegacyTokenMigrationResult.failed;
    }
  }

  static Future<void> removeLegacyTokenKeys(
    SharedPreferences preferences,
  ) async {
    await preferences.remove(legacyAccessTokenKey);
    await preferences.remove(legacyDuplicateAccessTokenKey);
    await preferences.remove(legacyRefreshTokenKey);
  }

  Future<void> _writeAndVerify(String key, String value) async {
    if (value.isEmpty) {
      await _store.delete(key);
      return;
    }
    await _store.write(key, value);
    final persisted = await _store.read(key);
    if (persisted != value) {
      throw StateError('Secure session value could not be verified');
    }
  }

  static String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      if (!_isEmpty(value)) return value;
    }
    return null;
  }

  static bool _isEmpty(String? value) => value == null || value.isEmpty;
}

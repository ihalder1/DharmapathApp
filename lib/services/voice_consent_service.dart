import 'dart:convert';

import '../constants/api_config.dart';
import 'authenticated_http.dart';
import 'secure_session_storage.dart';

enum VoiceConsentDecision { agree, disagree }

enum VoiceConsentSubmissionResult { success, failure }

abstract interface class VoiceConsentManager {
  Future<bool> hasCurrentConsent(String userId);

  Future<VoiceConsentSubmissionResult> submit({
    required String userId,
    required VoiceConsentDecision decision,
  });
}

abstract interface class VoiceConsentApi {
  Future<bool> submit({
    required VoiceConsentDecision decision,
    required DateTime timestamp,
  });
}

final class AuthenticatedVoiceConsentApi implements VoiceConsentApi {
  const AuthenticatedVoiceConsentApi();

  @override
  Future<bool> submit({
    required VoiceConsentDecision decision,
    required DateTime timestamp,
  }) async {
    final response = await AuthenticatedHttp.put(
      Uri.parse('${ApiConfig.baseUrl}${ApiConfig.consentEndpoint}'),
      body: jsonEncode(<String, String>{
        'consent': decision == VoiceConsentDecision.agree
            ? 'agree'
            : 'disagree',
        'timestamp': timestamp.toUtc().toIso8601String(),
      }),
    );
    return response.statusCode >= 200 && response.statusCode < 300;
  }
}

final class VoiceConsentService implements VoiceConsentManager {
  VoiceConsentService({
    SecureKeyValueStore? store,
    VoiceConsentApi? api,
    DateTime Function()? now,
  }) : _store = store ?? FlutterSecureKeyValueStore(),
       _api = api ?? const AuthenticatedVoiceConsentApi(),
       _now = now ?? DateTime.now;

  static const String currentVersion = '1.0';
  static const String storageKeyPrefix = 'voice_processing_consent_';

  final SecureKeyValueStore _store;
  final VoiceConsentApi _api;
  final DateTime Function() _now;

  static String storageKeyFor(String userId) => '$storageKeyPrefix$userId';

  @override
  Future<bool> hasCurrentConsent(String userId) async {
    if (userId.isEmpty) return false;
    try {
      final encoded = await _store.read(storageKeyFor(userId));
      if (encoded == null || encoded.isEmpty) return false;
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return false;
      return decoded['agreed'] == true &&
          decoded['version'] == currentVersion &&
          decoded['timestamp'] is String &&
          DateTime.tryParse(decoded['timestamp'] as String) != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<VoiceConsentSubmissionResult> submit({
    required String userId,
    required VoiceConsentDecision decision,
  }) async {
    if (userId.isEmpty) return VoiceConsentSubmissionResult.failure;
    final timestamp = _now().toUtc();
    try {
      final confirmed = await _api.submit(
        decision: decision,
        timestamp: timestamp,
      );
      if (!confirmed) return VoiceConsentSubmissionResult.failure;

      if (decision == VoiceConsentDecision.agree) {
        final value = jsonEncode(<String, Object>{
          'agreed': true,
          'version': currentVersion,
          'timestamp': timestamp.toIso8601String(),
        });
        final key = storageKeyFor(userId);
        await _store.write(key, value);
        if (await _store.read(key) != value) {
          return VoiceConsentSubmissionResult.failure;
        }
      } else {
        await _store.delete(storageKeyFor(userId));
      }
      return VoiceConsentSubmissionResult.success;
    } catch (_) {
      return VoiceConsentSubmissionResult.failure;
    }
  }
}

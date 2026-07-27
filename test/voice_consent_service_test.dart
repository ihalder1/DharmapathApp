import 'dart:convert';

import 'package:colab_app_ui/services/secure_session_storage.dart';
import 'package:colab_app_ui/services/voice_consent_service.dart';
import 'package:flutter_test/flutter_test.dart';

final class MemoryConsentStore implements SecureKeyValueStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

final class FakeConsentApi implements VoiceConsentApi {
  bool succeeds = true;
  VoiceConsentDecision? lastDecision;
  DateTime? lastTimestamp;
  int calls = 0;

  @override
  Future<bool> submit({
    required VoiceConsentDecision decision,
    required DateTime timestamp,
  }) async {
    calls += 1;
    lastDecision = decision;
    lastTimestamp = timestamp;
    return succeeds;
  }
}

void main() {
  const userId = 'user-123';
  final now = DateTime.utc(2026, 7, 27, 12, 30);
  late MemoryConsentStore store;
  late FakeConsentApi api;
  late VoiceConsentService service;

  setUp(() {
    store = MemoryConsentStore();
    api = FakeConsentApi();
    service = VoiceConsentService(store: store, api: api, now: () => now);
  });

  test('first login has no current consent', () async {
    expect(await service.hasCurrentConsent(userId), isFalse);
  });

  test('agreement is stored only after backend confirmation', () async {
    final result = await service.submit(
      userId: userId,
      decision: VoiceConsentDecision.agree,
    );

    expect(result, VoiceConsentSubmissionResult.success);
    expect(api.lastDecision, VoiceConsentDecision.agree);
    expect(api.lastTimestamp, now);
    final stored =
        jsonDecode(store.values[VoiceConsentService.storageKeyFor(userId)]!)
            as Map<String, dynamic>;
    expect(stored, <String, Object>{
      'agreed': true,
      'version': VoiceConsentService.currentVersion,
      'timestamp': now.toIso8601String(),
    });
    expect(await service.hasCurrentConsent(userId), isTrue);
  });

  test('failed agreement is not stored and remains blocked', () async {
    api.succeeds = false;

    final result = await service.submit(
      userId: userId,
      decision: VoiceConsentDecision.agree,
    );

    expect(result, VoiceConsentSubmissionResult.failure);
    expect(store.values, isEmpty);
    expect(await service.hasCurrentConsent(userId), isFalse);
  });

  test('decline is sent but never stored as consent', () async {
    final result = await service.submit(
      userId: userId,
      decision: VoiceConsentDecision.disagree,
    );

    expect(result, VoiceConsentSubmissionResult.success);
    expect(api.lastDecision, VoiceConsentDecision.disagree);
    expect(store.values, isEmpty);
    expect(await service.hasCurrentConsent(userId), isFalse);
  });

  test('failed decline leaves the user without consent', () async {
    api.succeeds = false;

    final result = await service.submit(
      userId: userId,
      decision: VoiceConsentDecision.disagree,
    );

    expect(result, VoiceConsentSubmissionResult.failure);
    expect(store.values, isEmpty);
  });

  test('consent is user-specific', () async {
    await service.submit(userId: userId, decision: VoiceConsentDecision.agree);

    expect(await service.hasCurrentConsent(userId), isTrue);
    expect(await service.hasCurrentConsent('different-user'), isFalse);
  });

  test('old consent versions automatically require consent again', () async {
    store.values[VoiceConsentService.storageKeyFor(userId)] = jsonEncode(
      <String, Object>{
        'agreed': true,
        'version': '0.9',
        'timestamp': now.toIso8601String(),
      },
    );

    expect(await service.hasCurrentConsent(userId), isFalse);
  });
}

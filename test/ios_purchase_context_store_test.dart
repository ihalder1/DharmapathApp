import 'package:colab_app_ui/models/ios_purchase.dart';
import 'package:colab_app_ui/services/ios_purchase_context_store.dart';
import 'package:colab_app_ui/services/secure_session_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _MemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'iOS context persists progress while keeping linkToken secure',
    () async {
      SharedPreferences.setMockInitialValues({});
      final secure = _MemorySecureStore();
      final store = IosPurchaseContextStore(secureStore: secure);
      final now = DateTime.utc(2026);
      final context = IosPurchaseContext(
        orderId: 'ORDER-1',
        linkToken: '123e4567-e89b-12d3-a456-426614174000',
        units: const [
          IosPurchaseUnit(storeProductId: 'ios_a', transactionId: 'tx-a'),
        ],
        currentIndex: 0,
        state: 'purchased',
        createdAt: now,
        updatedAt: now,
      );

      await store.save(context);
      final prefs = await SharedPreferences.getInstance();
      final persisted = prefs.getString('ios_purchase_context_v1')!;
      expect(persisted, isNot(contains(context.linkToken)));

      final restored = await store.load();
      expect(restored?.linkToken, context.linkToken);
      expect(restored?.units.single.transactionId, 'tx-a');

      await store.clear();
      expect(await store.load(), isNull);
    },
  );

  IosPurchaseContext context(String orderId, {String state = 'prepared'}) {
    final now = DateTime.utc(2026);
    return IosPurchaseContext(
      orderId: orderId,
      linkToken: orderId == 'ORDER-A'
          ? '123e4567-e89b-12d3-a456-426614174000'
          : '223e4567-e89b-12d3-a456-426614174000',
      units: const [IosPurchaseUnit(storeProductId: 'ios_a')],
      currentIndex: 0,
      state: state,
      createdAt: now,
      updatedAt: now,
    );
  }

  test('order B cannot overwrite unresolved order A', () async {
    SharedPreferences.setMockInitialValues({});
    final store = IosPurchaseContextStore(secureStore: _MemorySecureStore());
    await store.save(context('ORDER-A'));

    await expectLater(
      store.save(context('ORDER-B')),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'ios_unresolved_order_conflict',
        ),
      ),
    );
    expect((await store.load())?.orderId, 'ORDER-A');
  });

  test('order A can update its own persisted progress', () async {
    SharedPreferences.setMockInitialValues({});
    final store = IosPurchaseContextStore(secureStore: _MemorySecureStore());
    await store.save(context('ORDER-A'));
    await store.save(context('ORDER-A', state: 'purchased'));
    expect((await store.load())?.state, 'purchased');
  });

  test('order B can be saved only after order A is cleared', () async {
    SharedPreferences.setMockInitialValues({});
    final store = IosPurchaseContextStore(secureStore: _MemorySecureStore());
    await store.save(context('ORDER-A'));
    await store.clear();
    await store.save(context('ORDER-B'));
    expect((await store.load())?.orderId, 'ORDER-B');
  });
}

import 'package:colab_app_ui/models/ios_purchase.dart';
import 'package:colab_app_ui/services/ios_purchase_context_store.dart';
import 'package:colab_app_ui/services/storekit_diagnostics.dart';
import 'package:colab_app_ui/services/storekit_purchase_service.dart';
import 'package:colab_app_ui/services/storekit_read_only_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

final class _TrackingContextStore implements IosPurchaseContextStorage {
  _TrackingContextStore(this.context);
  IosPurchaseContext? context;
  int loads = 0;
  int saves = 0;
  int clears = 0;

  @override
  Future<IosPurchaseContext?> load() async {
    loads++;
    return context;
  }

  @override
  Future<void> save(IosPurchaseContext context) async => saves++;

  @override
  Future<void> clear() async => clears++;
}

void main() {
  test('read-only snapshot reads once and never mutates context', () async {
    final now = DateTime.utc(2026);
    final context = IosPurchaseContext(
      orderId: 'ORDER-12345678',
      linkToken: '123e4567-e89b-12d3-a456-426614174000',
      units: const [
        IosPurchaseUnit(
          storeProductId: 'ios_a',
          transactionId: '2000000123456789',
        ),
      ],
      currentIndex: 0,
      state: 'purchased',
      createdAt: now,
      updatedAt: now,
    );
    final store = _TrackingContextStore(context);
    var unfinishedReads = 0;
    final service = StoreKitReadOnlySnapshotService(
      contextStore: store,
      readUnfinishedTransactions: () async {
        unfinishedReads++;
        return const [
          StoreKitTransaction(
            productId: 'ios_a',
            status: PurchaseStatus.purchased,
            transactionId: '2000000123456789',
            appAccountToken: '123E4567-E89B-12D3-A456-426614174000',
          ),
        ];
      },
    );

    final snapshot = await service.capture();
    final diagnostics = StoreKitDiagnostics();
    service.log(snapshot, diagnostics);

    expect(store.loads, 1);
    expect(unfinishedReads, 1);
    expect(store.saves, 0);
    expect(store.clears, 0);
    expect(store.context, same(context));
    expect(diagnostics.text, contains('contextPresent=YES'));
    expect(diagnostics.text, contains('transactionId=****6789'));
    expect(diagnostics.text, contains('appAccountTokenSuffix=4000'));
    expect(diagnostics.text, contains('matchesPersistedContextToken=YES'));
    expect(diagnostics.text, contains('assignedToPersistedUnit=YES'));
    expect(diagnostics.text, isNot(contains('2000000123456789')));
    expect(diagnostics.text, isNot(contains('123E4567-E89B')));
  });
}

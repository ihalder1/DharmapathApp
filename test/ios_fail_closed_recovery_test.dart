import 'package:colab_app_ui/models/ios_purchase.dart';
import 'package:colab_app_ui/services/ios_fail_closed_recovery.dart';
import 'package:colab_app_ui/services/ios_purchase_context_store.dart';
import 'package:colab_app_ui/services/ios_purchase_reconciler.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MemoryContextStore implements IosPurchaseContextStorage {
  _MemoryContextStore(this.context);

  IosPurchaseContext? context;
  int saves = 0;
  int clears = 0;

  @override
  Future<IosPurchaseContext?> load() async => context;

  @override
  Future<void> save(IosPurchaseContext value) async {
    saves++;
    context = value;
  }

  @override
  Future<void> clear() async {
    clears++;
    context = null;
  }
}

IosPurchaseContext _context() {
  final now = DateTime.utc(2026);
  return IosPurchaseContext(
    orderId: 'ORDER-A',
    linkToken: '123e4567-e89b-12d3-a456-426614174000',
    units: const [IosPurchaseUnit(storeProductId: 'ios_a')],
    currentIndex: 0,
    state: 'purchased',
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  test('persisted context is established before reconciliation', () async {
    final events = <String>[];
    final guard = IosFailClosedRecovery(_MemoryContextStore(_context()));

    final result = await guard.recover(
      onContextEstablished: (_) => events.add('context-established'),
      reconcile: () async {
        events.add('reconcile');
        return IosReconciliationResult(context: _context());
      },
    );

    expect(events, ['context-established', 'reconcile']);
    expect(result.blocked, isTrue);
  });

  test('reconciliation HTTP exception retains context and blocks', () async {
    final saved = _context();
    final guard = IosFailClosedRecovery(_MemoryContextStore(saved));
    final result = await guard.recover(
      reconcile: () async => throw StateError('order_status_http_500'),
    );
    expect(result.context, same(saved));
    expect(result.blocked, isTrue);
    expect(result.error, isA<StateError>());
  });

  test('reconciliation Verify 500 retains context and blocks', () async {
    final saved = _context();
    final guard = IosFailClosedRecovery(_MemoryContextStore(saved));
    final result = await guard.recover(
      reconcile: () async => throw StateError('ios_verify_purchase_failed_500'),
    );
    expect(result.context, same(saved));
    expect(result.blocked, isTrue);
    expect(result.error.toString(), contains('ios_verify_purchase_failed_500'));
  });

  test('second Prepare operation cannot run with persisted context', () async {
    var prepareCalled = false;
    final guard = IosFailClosedRecovery(_MemoryContextStore(_context()));

    await expectLater(
      guard.runPrepareIfNoPending(() async {
        prepareCalled = true;
        return 'prepared';
      }),
      throwsA(isA<IosUnresolvedOrderConflict>()),
    );
    expect(prepareCalled, isFalse);
  });
}

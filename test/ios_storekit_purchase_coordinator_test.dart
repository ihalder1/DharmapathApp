import 'dart:async';

import 'package:colab_app_ui/services/ios_purchase_reconciler.dart';
import 'package:colab_app_ui/services/ios_storekit_purchase_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late IosStoreKitPurchaseCoordinator coordinator;

  setUp(() {
    coordinator = IosStoreKitPurchaseCoordinator.forTesting();
  });

  test('first purchase acquires and simultaneous purchase is rejected', () {
    coordinator.acquire(attemptId: 'IOSP-0001');

    expect(coordinator.purchaseActive, isTrue);
    expect(coordinator.activeAttemptId, 'IOSP-0001');
    expect(
      () => coordinator.acquire(attemptId: 'IOSP-0002'),
      throwsA(isA<IosStoreKitPurchaseAlreadyInFlight>()),
    );
  });

  for (final outcome in <String>[
    'success',
    'cancelled',
    'storekit_error',
    'timeout',
    'pending',
  ]) {
    test('lock releases after $outcome settlement', () async {
      coordinator.acquire(attemptId: 'IOSP-0001');
      coordinator.markStoreKitActive('IOSP-0001');
      if (outcome == 'success') {
        coordinator.markResultProcessing('IOSP-0001');
      }

      await coordinator.release('IOSP-0001');

      expect(coordinator.purchaseActive, isFalse);
      coordinator.acquire(attemptId: 'IOSP-0002');
      expect(coordinator.activeAttemptId, 'IOSP-0002');
    });
  }

  test(
    'resume reconciliation is deferred and coalesced while active',
    () async {
      coordinator.acquire(attemptId: 'IOSP-0001');
      var calls = 0;

      Future<IosReconciliationResult> reconcile() async {
        calls++;
        return const IosReconciliationResult(resolved: true);
      }

      expect(await coordinator.runOrDeferReconciliation(reconcile), isFalse);
      expect(await coordinator.runOrDeferReconciliation(reconcile), isFalse);
      expect(calls, 0);
      expect(coordinator.reconciliationDeferred, isTrue);

      await coordinator.release('IOSP-0001');

      expect(calls, 1);
      expect(coordinator.reconciliationDeferred, isFalse);
    },
  );

  test(
    'deferred reconciliation starts only after result processing ends',
    () async {
      coordinator.acquire(attemptId: 'IOSP-0001');
      coordinator.markResultProcessing('IOSP-0001');
      final entered = Completer<void>();
      final finish = Completer<void>();

      await coordinator.runOrDeferReconciliation(() async {
        expect(coordinator.state, IosStoreKitAttemptState.settling);
        entered.complete();
        await finish.future;
        return const IosReconciliationResult(resolved: true);
      });

      final releasing = coordinator.release('IOSP-0001');
      await entered.future;
      expect(coordinator.purchaseResultProcessingActive, isTrue);
      expect(
        () => coordinator.acquire(attemptId: 'IOSP-0002'),
        throwsA(isA<IosStoreKitPurchaseAlreadyInFlight>()),
      );
      finish.complete();
      await releasing;
      expect(coordinator.purchaseActive, isFalse);
    },
  );

  test('iOS checkout route guard rejects a double push until release', () {
    expect(coordinator.tryAcquireCheckoutRoute(), isTrue);
    expect(coordinator.tryAcquireCheckoutRoute(), isFalse);
    coordinator.releaseCheckoutRoute();
    expect(coordinator.tryAcquireCheckoutRoute(), isTrue);
  });

  test('checkout disposal keeps result delivery alive until settlement', () {
    final lifetime = IosStoreKitCheckoutLifetime();

    final cancelImmediately = lifetime.detach(purchaseProcessing: true);

    expect(cancelImmediately, isFalse);
    expect(lifetime.disposed, isTrue);
    expect(lifetime.mayNavigate, isFalse);
  });

  test('checkout disposal without a purchase cancels immediately', () {
    final lifetime = IosStoreKitCheckoutLifetime();

    expect(lifetime.detach(purchaseProcessing: false), isTrue);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:colab_app_ui/services/location_pricing_service.dart';
import 'package:colab_app_ui/services/mantra_sync_service.dart';

void main() {
  Map<String, dynamic> local(
    String id, {
    String? file,
    String modified = '2026-01-01T00:00:00Z',
  }) => {
    'song_id': id,
    'name': '$id name',
    'mantra_file': file ?? '$id.mp3',
    'icon': '$id.png',
    'last_modified': modified,
    'store_product_id_android': 'store_${id.toLowerCase()}',
    'price': 1,
  };

  Map<String, dynamic> api(
    String id, {
    String? file,
    String modified = '2026-01-01T00:00:00Z',
    bool urls = false,
  }) => {
    'id': id,
    'file_name': file ?? '$id.mp3',
    'last_updated': modified,
    'store_product_id_android': 'store_${id.toLowerCase()}',
    'price_other': '1.99',
    if (urls) 'audio_url': 'https://media.example/$id.mp3',
    if (urls) 'icon': 'https://media.example/$id.png',
  };

  CatalogReconciliation reconcile({
    required List<Map<String, dynamic>> apiRows,
    List<Map<String, dynamic>> localRows = const [],
    List<Map<String, dynamic>> bundledRows = const [],
  }) => MantraSyncService.reconcileCatalog(
    apiSongs: apiRows,
    localMantras: localRows,
    bundledMantras: bundledRows,
    pricingRegion: PricingRegion.other,
  );

  test('stable API and bundled ID match is visible without a download', () {
    final result = reconcile(
      apiRows: [api('F-AARATI-001')],
      bundledRows: [local('F-AARATI-001')],
    );
    expect(result.metadata['mantras'], hasLength(1));
    expect(result.downloads, isEmpty);
  });

  test('API-only song is visible and schedules persistent assets', () {
    final result = reconcile(apiRows: [api('NEW-001', urls: true)]);
    final row = (result.metadata['mantras'] as List).single as Map;
    expect(row['song_id'], 'NEW-001');
    expect(row['dynamic_assets_pending'], isTrue);
    expect(result.downloads.single.songId, 'NEW-001');
    expect(result.downloads.single.audioFileName, 'NEW-001.mp3');
  });

  test('local-only song is excluded by backend-authoritative visibility', () {
    final result = reconcile(
      apiRows: [api('VISIBLE-001')],
      localRows: [local('VISIBLE-001'), local('REMOVED-001')],
    );
    expect(result.metadata['mantras'], hasLength(1));
    expect(
      (result.metadata['mantras'] as List).single['song_id'],
      'VISIBLE-001',
    );
  });

  test('filename change does not replace a stable logical song', () {
    final result = reconcile(
      apiRows: [api('SAME-001', file: 'renamed.mp3')],
      bundledRows: [local('SAME-001', file: 'original.mp3')],
    );
    final row = (result.metadata['mantras'] as List).single as Map;
    expect(row['mantra_file'], 'original.mp3');
    expect(result.downloads, isEmpty);
  });

  test('legacy filename fallback migrates metadata to stable ID', () {
    final legacy = local('LEGACY-001')..remove('song_id');
    final result = reconcile(
      apiRows: [api('LEGACY-001')],
      bundledRows: [legacy],
    );
    final row = (result.metadata['mantras'] as List).single as Map;
    expect(row['song_id'], 'LEGACY-001');
    expect(result.downloads, isEmpty);
  });

  test('only a meaningfully updated song schedules asset refresh', () {
    final result = reconcile(
      apiRows: [
        api('UNCHANGED-001', urls: true),
        api('UPDATED-001', modified: '2026-01-02T00:00:00Z', urls: true),
      ],
      bundledRows: [local('UNCHANGED-001'), local('UPDATED-001')],
    );
    expect(result.downloads.map((item) => item.songId), ['UPDATED-001']);
  });
}

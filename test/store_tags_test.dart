import 'dart:async';

import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/checkout/data/store_tags.dart';
import 'package:altai_pos/features/checkout/domain/basket.dart';
import 'package:altai_pos/features/checkout/domain/basket_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tag check that never answers: the item stays "checking", as on a slow network.
class NeverAnswers implements CheckoutApi {
  @override
  Future<List<Map<String, dynamic>>> inspect(List<String> epcs, {void Function(Map<String, dynamic> tag)? onEach}) =>
      Completer<List<Map<String, dynamic>>>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> row(String epc, String sku) =>
    {'epc': epc, 'sku': sku, 'productName': 'Classic Tee', 'productCode': 'CT', 'varLabel': 'Black / M'};

void main() {
  test('loads every page, then answers by EPC (any case)', () async {
    final asked = <int>[];
    final tags = StoreTags((page) async {
      asked.add(page);
      return switch (page) {
        1 => (rows: [row('AA000001', 'CT-BLK-M'), row('AA000002', 'CT-BLK-M')], total: 3),
        2 => (rows: [row('AA000003', 'CT-BLK-L')], total: 3),
        _ => (rows: <Map<String, dynamic>>[], total: 3),
      };
    });
    await tags.load();
    expect(asked, [1, 2]); // stops once all 3 are in
    expect(tags.count, 3);
    expect(tags['aa000003']?.sku, 'CT-BLK-L');
    expect(tags['AA000001']?.variation, 'Black / M');
    expect(tags['FF000000'], isNull);
  });

  test('a failed refresh keeps the list it had', () async {
    var fail = false;
    final tags = StoreTags((page) async {
      if (fail) throw Exception('offline');
      return (rows: [row('AA000001', 'CT-BLK-M')], total: 1);
    });
    await tags.load();
    fail = true;
    await tags.load();
    expect(tags['AA000001']?.sku, 'CT-BLK-M');
  });

  test('a scanned tag the list knows shows its name at once, still waiting for the check', () async {
    final tags = StoreTags((page) async => (rows: [row('AA000001', 'CT-BLK-M')], total: 1));
    await tags.load();
    final basket = BasketController(api: NeverAnswers(), storeId: '12', known: tags, checkDelay: Duration.zero);
    basket.addText('AA000001 BB000002');

    final known = basket.items.firstWhere((i) => i.epc == 'AA000001');
    expect(known.state, ItemState.checking); // not sellable until the server says so
    expect(known.productName, 'Classic Tee');
    expect(known.sku, 'CT-BLK-M');
    expect(basket.items.firstWhere((i) => i.epc == 'BB000002').productName, isNull); // not in the list
    expect(basket.canComplete, isFalse);
    basket.dispose();
  });
}

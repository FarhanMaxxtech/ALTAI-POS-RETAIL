import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/checkout/domain/basket.dart';
import 'package:altai_pos/features/orders/domain/order.dart';
import 'package:altai_pos/features/returns/data/returns_api.dart';
import 'package:altai_pos/features/returns/domain/return_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'returns_test.dart' show FakeTeam;

// FakeTeam's tag lookup says every tag is a sold Classic Tee, Black / M (CT-BLK-M).
const a = 'E2801160000000A1', b = 'E2801160000000A2', c = 'E2801160000000A3';

StoreHubOrder order({
  List<OrderLine> lines = const [OrderLine(sku: 'CT-BLK-M', name: 'Classic Tee', variation: 'Black / M', qty: 2)],
  List<String> soldEpcs = const [],
  Map<String, int> returned = const {},
  Set<String> returnedEpcs = const {},
}) => StoreHubOrder(
  refId: 'r1',
  invoiceNumber: '0022611171402118',
  storeId: '12',
  registerId: '1',
  paidAt: DateTime(2026, 11, 17, 14, 2),
  lines: lines,
  status: OrderStatus.completed,
  soldEpcs: soldEpcs,
  returned: returned,
  returnedEpcs: returnedEpcs,
);

void main() {
  group('returnRejectReason', () {
    test('fits: on the order, pieces left', () {
      expect(returnRejectReason(order(), epc: a, sku: 'CT-BLK-M', alreadyComing: 1), isNull);
    });
    test('not on the order', () {
      expect(returnRejectReason(order(), epc: a, sku: 'JN-32', alreadyComing: 0), 'Not in this order');
      expect(returnRejectReason(order(), epc: a, sku: null, alreadyComing: 0), 'Not in this order');
    });
    test('no more than the order has', () {
      expect(returnRejectReason(order(), epc: a, sku: 'CT-BLK-M', alreadyComing: 2), 'Order has only 2 of this to return');
    });
    test('pieces returned before count', () {
      final o = order(returned: {'CT-BLK-M': 1});
      expect(returnRejectReason(o, epc: a, sku: 'CT-BLK-M', alreadyComing: 1), 'Order has only 1 of this to return');
      final all = order(returned: {'CT-BLK-M': 2});
      expect(returnRejectReason(all, epc: a, sku: 'CT-BLK-M', alreadyComing: 0), 'All 2 already returned');
    });
    test('a tag already returned on it, or not sold on it, can\'t come back', () {
      expect(returnRejectReason(order(returnedEpcs: {a}), epc: a, sku: 'CT-BLK-M', alreadyComing: 0),
          'Already returned on this order');
      expect(returnRejectReason(order(soldEpcs: [b]), epc: a, sku: 'CT-BLK-M', alreadyComing: 0), 'Not sold on this order');
      expect(returnRejectReason(order(soldEpcs: [a]), epc: a, sku: 'CT-BLK-M', alreadyComing: 0), isNull);
    });
    test('a tag-free line (a paper bag) never comes back', () {
      final o = order(lines: const [OrderLine(sku: 'BAG', name: 'Paper bag', qty: 1, exempt: true)]);
      expect(returnRejectReason(o, epc: a, sku: 'BAG', alreadyComing: 0), 'Not in this order');
    });
  });

  test('withReturn adds up what came back', () {
    final o = order().withReturn({'CT-BLK-M': 1}, [a]).withReturn({'CT-BLK-M': 1}, [b]);
    expect(o.returned, {'CT-BLK-M': 2});
    expect(o.returnedEpcs, {a, b});
    expect(o.returnableQty('CT-BLK-M'), 0);
  });

  group('return on an order', () {
    Future<ReturnController> scan(StoreHubOrder? o, List<String> tags) async {
      final team = FakeTeam();
      final r = ReturnController(
        inspector: CheckoutApi(team.api),
        api: ReturnsApi(team.api),
        storeId: '12',
        checkDelay: Duration.zero,
        order: o,
      );
      r.addText(tags.join(' '));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return r;
    }

    ItemState state(ReturnController r, String epc) => r.items.firstWhere((i) => i.epc == epc).state;
    String? why(ReturnController r, String epc) => r.items.firstWhere((i) => i.epc == epc).problem;

    test('the order\'s receipt no. is used', () async {
      final r = await scan(order(), []);
      expect(r.receiptNo, '0022611171402118');
      r.dispose();
    });

    test('more pieces than ordered: the extra one is red', () async {
      final r = await scan(order(), [a, b, c]);
      expect([state(r, a), state(r, b)], [ItemState.ok, ItemState.ok]);
      expect(state(r, c), ItemState.problem);
      expect(why(r, c), 'Order has only 2 of this to return');
      expect(r.piecesBySku, {'CT-BLK-M': 2});
      r.dispose();
    });

    test('not on the order: red', () async {
      final r = await scan(order(lines: const [OrderLine(sku: 'JN-32', name: 'Slim Jeans', qty: 1)]), [a]);
      expect(why(r, a), 'Not in this order');
      r.dispose();
    });

    test('a tag already returned on the order: red', () async {
      final r = await scan(order(returnedEpcs: {a}, returned: {'CT-BLK-M': 1}), [a, b]);
      expect(why(r, a), 'Already returned on this order');
      expect(state(r, b), ItemState.ok);
      r.dispose();
    });

    test('picking the order after scanning checks the items again', () async {
      final r = await scan(null, [a, b, c]);
      expect(r.okCount, 3); // no order: any sold tag
      r.useOrder(order());
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(r.okCount, 2);
      expect(r.receiptNo, '0022611171402118');
      r.dispose();
    });
  });
}

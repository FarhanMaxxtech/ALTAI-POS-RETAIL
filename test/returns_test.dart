import 'dart:convert';

import 'package:altai_pos/core/api_client.dart';
import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:altai_pos/features/checkout/domain/basket.dart';
import 'package:altai_pos/features/returns/data/returns_api.dart';
import 'package:altai_pos/features/returns/domain/return_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// The team's API, faked: answers by path and remembers every call. Nothing leaves the computer.
class FakeTeam {
  final calls = <String>[];
  final bodies = <String, Map<String, dynamic>>{};
  http.Response? Function(String path)? override;
  final savedRemarks = <String>[];

  late final api = ApiClient(
      client: MockClient((req) async {
        final path = req.url.path.replaceFirst('/rest/', '');
        calls.add(path);
        if (req.body.isNotEmpty) bodies[path] = jsonDecode(req.body) as Map<String, dynamic>;
        final o = override?.call(path);
        if (o != null) return o;
        switch (path) {
          case 'Stock/TagLookup':
            return json({'sku': 'CT-BLK-M', 'productName': 'Classic Tee', 'varLabel': 'Black / M'});
          case 'Stock/EpcList':
            return json({'data': []});
          case 'Stock/Adjustment':
            savedRemarks.add(bodies[path]!['remark'] as String);
            return json({'trxId': 77});
          case 'Stock/AdjustmentApproveNoScan':
            return json({'trxId': 77});
          case 'Stock/AdjustmentList':
            return json({
              'data': [for (final r in savedRemarks) {'id': 77, 'trxId': 'ADJ-77', 'remark': r}]
            });
        }
        return json({'error': 'unexpected $path'});
      }),
      baseUrl: 'https://team.test/rest',
      apiKey: 'test-key');

  int count(String path) => calls.where((c) => c == path).length;
}

Future<ReturnController> readyReturn(FakeTeam team) async {
  final r = ReturnController(
      inspector: CheckoutApi(team.api), api: ReturnsApi(team.api), storeId: '12', staffName: 'Aina',
      checkDelay: Duration.zero);
  r.addText('E2801160000000A1');
  await Future<void>.delayed(const Duration(milliseconds: 20));
  r.setReceipt('R-1042');
  r.setReason('Wrong size');
  return r;
}

void main() {
  test('needs items, a receipt and a reason before it can be sent', () async {
    final team = FakeTeam();
    final r = ReturnController(
        inspector: CheckoutApi(team.api), api: ReturnsApi(team.api), storeId: '12', checkDelay: Duration.zero);
    expect(r.missing, 'Scan the items coming back.');
    r.addText('E2801160000000A1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(r.missing, 'Enter or scan the receipt / order number.');
    r.setReceipt('R-1042');
    expect(r.missing, 'Pick a reason.');
    r.setReason('Defective');
    expect(r.canSubmit, isTrue);
  });

  test('a tag with no product is left out of the return, with a note', () async {
    final team = FakeTeam()
      ..override = (p) => p == 'Stock/TagLookup' ? json({'error': {'message': 'Tag not found'}}) : null;
    final r = await readyReturn(team);
    expect(r.items, isEmpty);
    expect(r.ignoredUnknown, 1);
    expect(r.message, '1 unknown tag ignored (no product).');
    expect(r.canSubmit, isFalse); // nothing left to return
  });

  test('saves a Stock In adjustment, then approves it', () async {
    final team = FakeTeam();
    final r = await readyReturn(team);
    await r.submit();

    expect(r.phase, ReturnPhase.done);
    expect(r.trxId, '77');
    final save = team.bodies['Stock/Adjustment']!;
    expect(save['trxType'], 'ADI');
    expect(save['storeId'], '12');
    expect(save['epcs'], ['E2801160000000A1']);
    expect(save['remark'], startsWith('Return · receipt R-1042 · Wrong size · Aina · ref '));
    expect(team.bodies['Stock/AdjustmentApproveNoScan']!['id'], '77');
  });

  test('no answer to the save: Try again finds it and only approves, never saves twice', () async {
    final team = FakeTeam();
    var first = true;
    team.override = (p) {
      if (p == 'Stock/Adjustment' && first) {
        first = false;
        team.savedRemarks.add(team.bodies[p]!['remark'] as String); // it went through…
        throw http.ClientException('connection reset'); // …but the answer was lost
      }
      return null;
    };
    final r = await readyReturn(team);
    await r.submit();
    expect(r.phase, ReturnPhase.retry);

    await r.submit();
    expect(r.phase, ReturnPhase.done);
    expect(team.count('Stock/Adjustment'), 1);
    expect(team.count('Stock/AdjustmentList'), 1);
    expect(team.bodies['Stock/AdjustmentApproveNoScan']!['id'], '77');
  });

  test('approval refused: stays saved, Try again approves the same one', () async {
    final team = FakeTeam();
    var refuse = true;
    team.override = (p) {
      if (p == 'Stock/AdjustmentApproveNoScan' && refuse) {
        refuse = false;
        return json({'error': {'message': 'Not allowed'}});
      }
      return null;
    };
    final r = await readyReturn(team);
    await r.submit();
    expect(r.phase, ReturnPhase.notApproved);
    expect(r.message, 'Not allowed');

    await r.submit();
    expect(r.phase, ReturnPhase.done);
    expect(team.count('Stock/Adjustment'), 1);
    expect(team.count('Stock/AdjustmentApproveNoScan'), 2);
  });

  test('save refused: nothing changed, staff can fix it and send again', () async {
    final team = FakeTeam()
      ..override = (p) => p == 'Stock/Adjustment' ? json({'error': {'message': 'Store closed'}}) : null;
    final r = await readyReturn(team);
    await r.submit();
    expect(r.phase, ReturnPhase.scanning);
    expect(r.message, 'Store closed');
    expect(team.count('Stock/AdjustmentApproveNoScan'), 0);
  });

  test('a piece still in stock (never sold): marked red with the reason, nothing saved', () async {
    final team = FakeTeam()
      ..override = (p) => p == 'Stock/Adjustment'
          ? json({'error': 'EPC [E2801160000000A1] is already assigned to Subang Jaya (GB1) - cannot adjust in again.'})
          : null;
    final r = await readyReturn(team);
    await r.submit();
    expect(r.phase, ReturnPhase.scanning);
    expect(r.message, '1 piece is still in stock, so not sold. Remove the red one and submit again. Nothing was saved.');
    final item = r.items.single;
    expect(item.state, ItemState.problem);
    expect(item.problem, "Still in stock at Subang Jaya (GB1): it was never sold, so it can't be returned");
    expect(item.productName, 'Classic Tee');
    expect(r.canSubmit, isFalse);
    expect(team.count('Stock/AdjustmentApproveNoScan'), 0);
  });

  test('a piece still in a store\'s stock was never sold, so it can\'t be returned', () {
    final inStock = returnItemFromInspection(
        {'epc': 'A1', 'found': true, 'store_id': '12', 'store_name': 'Subang Jaya'});
    expect(inStock.state, ItemState.problem);
    expect(inStock.problem, contains('Still in stock at Subang Jaya'));

    // sold: no store any more, so it can come back
    final sold = returnItemFromInspection({'epc': 'A1', 'found': true});
    expect(sold.state, ItemState.ok);
  });
}

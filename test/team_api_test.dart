import 'dart:convert';

import 'package:altai_pos/core/api_client.dart';
import 'package:altai_pos/features/checkout/data/checkout_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The team's API, faked with MockClient: nothing leaves the computer.
ApiClient clientFor(Future<http.Response> Function(http.Request req) handler) =>
    ApiClient(client: MockClient(handler), baseUrl: 'https://team.test/rest', apiKey: 'test-key');

http.Response json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...headers});

void main() {
  test('sends the key, session and merchant headers', () async {
    late http.Request seen;
    final api = clientFor((req) async {
      seen = req;
      return json({'data': []});
    })
      ..session = 's1'
      ..merchantId = '7';
    await api.get('Stock/StoreList');
    expect(seen.url.toString(), 'https://team.test/rest/Stock/StoreList');
    expect(seen.headers['APIKEY'], 'test-key');
    expect(seen.headers['SESSION'], 's1');
    expect(seen.headers['MERCHANTID'], '7');
  });

  test('login reads the session from the response header', () async {
    final api = clientFor((req) async =>
        json({'name': 'Aina', 'merchantId': 7}, 200, {'session': 'abc'}));
    final res = await api.login({'loginId': 'aina', 'password': 'x'});
    expect(res.session, 'abc');
    expect(res.merchantId, '7');
    expect(res.name, 'Aina');
  });

  test('a 200 with { error } is a refusal, with their message', () async {
    final api = clientFor((req) async => json({'error': {'message': 'Wrong password'}}));
    await expectLater(api.login({'loginId': 'a', 'password': 'b'}),
        throwsA(isA<ApiException>().having((e) => e.refused, 'refused', true).having((e) => e.message, 'message', 'Wrong password')));
  });

  test('440: logs in again once for many calls at the same moment, then retries each', () async {
    var logins = 0;
    final api = clientFor((req) async =>
        req.headers['SESSION'] == 'fresh' ? json({'ok': true}) : http.Response('', 440))
      ..session = 'old';
    api.onSessionExpired = () async {
      logins++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      api.session = 'fresh';
      return true;
    };
    final results = await Future.wait([for (var i = 0; i < 5; i++) api.get('Stock/StoreList')]);
    expect(results.every((r) => r['ok'] == true), isTrue);
    expect(logins, 1);
  });

  test('440 on a call sent before the new login: goes again with the new session, no second login', () async {
    var logins = 0;
    var current = 'fresh-0'; // the server knows only the newest session of a login
    final api = clientFor((req) async {
      final ok = req.headers['SESSION'] == current;
      // Stock/Slow answers late: it comes back after the other call has already logged in again.
      if (req.url.path.endsWith('Slow')) await Future<void>.delayed(const Duration(milliseconds: 30));
      return ok ? json({'ok': true}) : http.Response('', 440);
    })
      ..session = 'old';
    api.onSessionExpired = () async {
      logins++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      current = 'fresh-$logins'; // a new login ends the one before
      api.session = current;
      return true;
    };
    final results = await Future.wait([api.get('Stock/StoreList'), api.get('Stock/Slow')]);
    expect(results.every((r) => r['ok'] == true), isTrue);
    expect(logins, 1);
  });

  test('440 with no way to log in again: says the session expired', () async {
    final api = clientFor((req) async => http.Response('', 440));
    await expectLater(api.get('Stock/StoreList'),
        throwsA(isA<ApiException>().having((e) => e.sessionExpired, 'sessionExpired', true)));
  });

  test('440 that cannot be renewed: tells the app (back to the login screen)', () async {
    var lost = 0;
    final api = clientFor((req) async => http.Response('', 440))
      ..onSessionExpired = (() async => false)
      ..onSessionLost = () => lost++;
    await expectLater(api.get('Stock/StoreList'), throwsA(isA<ApiException>()));
    expect(lost, 1);
  });

  test('440 renewed by logging in again: the app stays where it is', () async {
    var lost = 0;
    final api = clientFor((req) async =>
        req.headers['SESSION'] == 'new' ? json({'ok': true}) : http.Response('', 440))
      ..session = 'old';
    api
      ..onSessionExpired = () async {
        api.session = 'new';
        return true;
      }
      ..onSessionLost = () => lost++;
    await api.get('Stock/StoreList');
    expect(lost, 0);
  });

  test('no API key: refuses to call at all', () async {
    var calls = 0;
    final api = ApiClient(client: MockClient((req) async {
      calls++;
      return json({});
    }), apiKey: '');
    await expectLater(api.get('Stock/StoreList'), throwsA(isA<ApiException>()));
    expect(calls, 0);
  });

  test('pictures: a path gets the website in front of it', () {
    final api = clientFor((req) async => json({}));
    expect(api.imageUrl('/product/a.jpg'), 'https://team.test/product/a.jpg');
    expect(api.imageUrl('https://cdn.test/b.jpg'), 'https://cdn.test/b.jpg');
  });

  test('inspect: TagLookup for each tag, EpcList for the store, unknown tags marked', () async {
    final api = clientFor((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      if (req.url.path.endsWith('Stock/EpcList')) {
        return json({'data': [{'epc': 'E2801160000000A1', 'storeId': 12, 'storeName': 'MidValley'}]});
      }
      if (body['epc'] == 'E2801160000000A1') {
        return json({'epc': body['epc'], 'sku': 'CT', 'productName': 'Classic Tee', 'varLabel': 'Black / M'});
      }
      return json({'error': 'Tag not found'});
    });
    final tags = await CheckoutApi(api).inspect(['E2801160000000A1', 'E2801160000000B2']);
    expect(tags[0], containsPair('found', true));
    expect(tags[0], containsPair('store_id', '12'));
    expect(tags[0], containsPair('product_name', 'Classic Tee'));
    expect(tags[1], containsPair('found', false));
  });

  test('checkout puts the ref in the remark, and findByRef finds it in the list', () async {
    final api = clientFor((req) async {
      if (req.url.path.endsWith('Stock/Checkout')) {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['remark'], matches(RegExp(r'^Altai POS · Aina · \d{2}:\d{2}:\d{2} · ref r1$')));
        return json({'trxId': 501});
      }
      return json({'data': [{'id': 9, 'trxId': 501, 'remark': 'Altai POS · Aina · ref r1'}]});
    });
    final checkouts = CheckoutApi(api);
    expect(await checkouts.checkout(storeId: '12', clientRef: 'r1', epcs: ['E2801160000000A1'], staffName: 'Aina'), '501');
    expect(await checkouts.findByRef('12', 'r1'), '501');
    expect(await checkouts.findByRef('12', 'r2'), isNull);
  });
}

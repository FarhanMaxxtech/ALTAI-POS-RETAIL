import 'dart:convert';

import 'package:altai_pos/core/api_client.dart';
import 'package:altai_pos/features/auth/data/auth_api.dart';
import 'package:altai_pos/features/auth/data/session_store.dart';
import 'package:altai_pos/features/auth/domain/staff.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response json(Object body, [Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json', ...headers});

/// Staff "aina" can see store 12 only; "boss" can see 12 and 14.
ApiClient fakeTeam() => ApiClient(
    client: MockClient((req) async {
      if (req.url.path.endsWith('Merchant/Login')) {
        final id = (jsonDecode(req.body) as Map)['loginId'];
        return json({'name': id, 'merchantId': 7}, {'session': 's-$id'});
      }
      final stores = [
        {'id': 12, 'name': 'MidValley'},
        if (req.headers['SESSION'] == 's-boss') {'id': 14, 'name': 'Pavilion'},
      ];
      return json({'data': stores});
    }),
    baseUrl: 'https://team.test/rest',
    apiKey: 'test-key');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('a manager lists stores without staying logged in', () async {
    final api = fakeTeam();
    final auth = AuthApi(api, SessionStore());
    final stores = await auth.storesFor('boss', 'x');
    expect(stores.map((s) => s.name), ['MidValley', 'Pavilion']);
    expect(api.session, isNull);
  });

  test('staff log in at the preset location', () async {
    final api = fakeTeam();
    final auth = AuthApi(api, SessionStore());
    final staff = await auth.login('aina', 'x', location: const Store(id: '12', name: 'MidValley'));
    expect(staff.name, 'aina');
    expect(api.session, 's-aina');
  });

  test('refused when the account cannot use that store, and nobody stays logged in', () async {
    final api = fakeTeam();
    final auth = AuthApi(api, SessionStore());
    await expectLater(auth.login('aina', 'x', location: const Store(id: '14', name: 'Pavilion')),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('Pavilion'))));
    expect(api.session, isNull);
    expect(await SessionStore().load(), isNull);
  });

  test('the location stays when staff log out', () async {
    final auth = AuthApi(fakeTeam(), SessionStore());
    await auth.setLocation(const Store(id: '12', name: 'MidValley'));
    await auth.login('aina', 'x', location: const Store(id: '12', name: 'MidValley'));
    await auth.logout();
    expect((await auth.location())?.name, 'MidValley');
    expect(await SessionStore().load(), isNull);
  });
}

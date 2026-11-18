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

  test('staff log in first, then see only the stores they can use', () async {
    final api = fakeTeam();
    final auth = AuthApi(api, SessionStore());
    final staff = await auth.login('aina', 'x');
    expect(staff.name, 'aina');
    expect(api.session, 's-aina');
    expect((await auth.stores()).map((s) => s.name), ['MidValley']);

    final boss = AuthApi(fakeTeam(), SessionStore());
    await boss.login('boss', 'x');
    expect((await boss.stores()).map((s) => s.name), ['MidValley', 'Pavilion']);
  });

  test('the last store stays when staff log out, to offer it first next time', () async {
    final auth = AuthApi(fakeTeam(), SessionStore());
    await auth.login('aina', 'x');
    await auth.setLocation(const Store(id: '12', name: 'MidValley'));
    await auth.logout();
    expect((await auth.location())?.name, 'MidValley');
    expect(await SessionStore().load(), isNull);
  });

  test('the app was closed and Altai ended the session: logs in again by itself, no login screen', () async {
    await AuthApi(fakeTeam(), SessionStore())
        .login('aina', 'x');

    // The app opens again. Altai has ended s-aina meanwhile; a new login gives new-aina.
    var logins = 0;
    final api = ApiClient(
        client: MockClient((req) async {
          if (req.url.path.endsWith('Merchant/Login')) {
            logins++;
            expect(jsonDecode(req.body), {'loginId': 'aina', 'password': 'x'});
            return json({'name': 'aina', 'merchantId': 7}, {'session': 'new-aina'});
          }
          if (req.headers['SESSION'] != 'new-aina') return http.Response('', 440);
          return json({
            'data': [
              {'id': 12, 'name': 'MidValley'},
            ],
          });
        }),
        baseUrl: 'https://team.test/rest',
        apiKey: 'test-key');
    final saved = await AuthApi(api, SessionStore()).restore();

    expect(saved?.staffName, 'aina'); // straight in, no login screen
    expect(logins, 1);
    expect(api.session, 'new-aina');
    expect((await SessionStore().load())?.session, 'new-aina');
  });

  test('log out forgets the saved login, password included', () async {
    final auth = AuthApi(fakeTeam(), SessionStore());
    await auth.login('aina', 'x');
    expect((await SessionStore().load())?.password, 'x');
    await auth.logout();
    expect(await const FlutterSecureStorage().read(key: 'password'), isNull);
    expect(await const FlutterSecureStorage().read(key: 'loginId'), isNull);
  });
}

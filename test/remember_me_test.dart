import 'package:altai_pos/features/auth/data/auth_api.dart';
import 'package:altai_pos/features/auth/data/session_store.dart';
import 'package:altai_pos/features/auth/presentation/login_screen.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'location_test.dart' show fakeTeam;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('Remember me keeps the login after log out; logging in without it forgets it', () async {
    final auth = AuthApi(fakeTeam(), SessionStore());
    await auth.login('aina', 'secret', remember: true);
    await auth.logout();
    expect(await auth.remembered(), (loginId: 'aina', password: 'secret'));

    await auth.login('boss', 'other');
    expect(await auth.remembered(), isNull);
  });

  testWidgets('the login screen fills in the remembered login, with the box ticked', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({'rememberLoginId': 'aina', 'rememberPassword': 'secret'});
    await tester.pumpWidget(MaterialApp(
      theme: altaiTheme(Brightness.light),
      home: LoginScreen(auth: AuthApi(fakeTeam(), SessionStore()), onLoggedIn: (_) {}),
    ));
    await tester.pumpAndSettle();
    expect(find.text('aina'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);

    await tester.tap(find.byKey(const ValueKey('remember-me')));
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
  });
}

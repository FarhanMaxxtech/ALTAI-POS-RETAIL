import 'package:altai_pos/core/api_client.dart';
import 'package:altai_pos/features/auth/data/auth_api.dart';
import 'package:altai_pos/features/auth/data/session_store.dart';
import 'package:altai_pos/features/auth/presentation/login_screen.dart';
import 'package:altai_pos/shared/altai_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The tablet (SM-X610) in landscape: 1205 × 753, with and without the on-screen keyboard.
  for (final (name, keyboard) in [('no keyboard', 0.0), ('keyboard up', 420.0)]) {
    testWidgets('the login screen fits ($name)', (tester) async {
      tester.view.physicalSize = const Size(1205, 753);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: altaiTheme(Brightness.light),
        home: LoginScreen(auth: AuthApi(ApiClient(), SessionStore()), onLoggedIn: (_) {}),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull); // no "overflowed" stripes
      expect(find.text('Log in'), findsWidgets);
      expect(find.textContaining('straight from the tags'), keyboard == 0 ? findsOneWidget : findsNothing);
    });
  }
}

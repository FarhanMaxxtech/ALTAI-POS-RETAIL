import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/keyboard.dart';
import '../data/auth_api.dart';
import '../domain/staff.dart';

/// Staff log in with their account from the team's system. The store is picked right after, from
/// the stores this account can use.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth, required this.onLoggedIn, this.notice});

  final AuthApi auth;
  final void Function(Staff staff) onLoggedIn;

  /// Why the login screen is back, e.g. the session ended. Shown until the next try.
  final String? notice;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _loginId = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hidePassword = true;
  late String? _error = widget.notice;

  @override
  void dispose() {
    _loginId.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.onLoggedIn(await widget.auth.login(_loginId.text.trim(), _password.text));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    OutlineInputBorder border(Color color, double w) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: color, width: w));
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: AltaiType.caption.copyWith(fontSize: 13, fontWeight: FontWeight.w500, color: c.inkMuted)),
    );
    InputDecoration field(IconData icon, {Widget? suffix}) => InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      prefixIcon: Icon(icon, size: 22, color: c.inkMuted),
      suffixIcon: suffix,
      enabledBorder: border(c.border, 1),
      focusedBorder: border(c.brand, 1.5),
    );

    final form = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Log in', style: AltaiType.title.copyWith(fontSize: 34, fontWeight: FontWeight.w700, color: c.ink)),
            const SizedBox(height: 4),
            Text('Use your Altai account.', style: AltaiType.body.copyWith(fontSize: 17, color: c.inkMuted)),
            const SizedBox(height: 28),
            label('Login ID'),
            TextField(
              onTap: showKeyboard,
              controller: _loginId,
              style: AltaiType.body.copyWith(color: c.ink),
              decoration: field(Icons.person_outline_rounded),
              textInputAction: TextInputAction.next,
              autocorrect: false,
              autofillHints: const [AutofillHints.username],
            ),
            const SizedBox(height: 16),
            label('Password'),
            TextField(
              onTap: showKeyboard,
              controller: _password,
              style: AltaiType.body.copyWith(color: c.ink),
              decoration: field(
                Icons.lock_outline_rounded,
                suffix: IconButton(
                  tooltip: _hidePassword ? 'Show password' : 'Hide password',
                  onPressed: () => setState(() => _hidePassword = !_hidePassword),
                  icon: Icon(_hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined, color: c.inkMuted),
                ),
              ),
              obscureText: _hidePassword,
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[const SizedBox(height: D.space4), AltaiNotice(_error!)],
            const SizedBox(height: 24),
            AltaiButton(
              _busy ? 'Logging in…' : 'Log in',
              onPressed: _busy ? null : _submit,
              variant: AltaiButtonVariant.primary,
              icon: Icons.login_rounded,
              expand: true,
            ),
          ],
        ),
      ),
    );

    final brand = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [c.logoGreenTop, c.logoGreenBottom],
        ),
      ),
      padding: const EdgeInsets.all(64),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AltaiLogo(height: 72, full: true),
          const Spacer(),
          Text(
            'Checkout and returns,\nstraight from the tags.',
            style: AltaiType.title.copyWith(fontSize: 40, height: 1.25, fontWeight: FontWeight.w700, color: c.onLogoGreen),
          ),
          const SizedBox(height: 16),
          Text(
            'Put the items near the reader. Altai POS does the rest.',
            style: AltaiType.body.copyWith(color: c.onLogoGreen.withValues(alpha: 0.85)),
          ),
          const SizedBox(height: 64),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: c.surface100,
      body: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth >= 900) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: box.maxWidth * 0.44, child: brand),
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(padding: const EdgeInsets.all(D.space8), child: form),
                  ),
                ),
              ],
            );
          }
          // Portrait: the logo on top, the form under it.
          return SingleChildScrollView(
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: D.space8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [c.logoGreenTop, c.logoGreenBottom],
                    ),
                  ),
                  child: const Center(child: AltaiLogo(height: 96, full: true)),
                ),
                Padding(padding: const EdgeInsets.all(D.space8), child: form),
              ],
            ),
          );
        },
      ),
    );
  }
}

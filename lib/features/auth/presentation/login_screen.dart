import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/keyboard.dart';
import '../data/auth_api.dart';
import '../domain/staff.dart';
import 'location_screen.dart';

/// Staff log in with their account from the team's system, at the tablet's preset location.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.auth,
    required this.location,
    required this.onLocationSet,
    required this.onLoggedIn,
  });

  final AuthApi auth;

  /// The store this tablet is in. Null until a manager sets it: nobody can log in before that.
  final Store? location;
  final void Function(Store store) onLocationSet;
  final void Function(Staff staff) onLoggedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _loginId = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hidePassword = true;
  String? _error;

  @override
  void dispose() {
    _loginId.dispose();
    _password.dispose();
    super.dispose();
  }

  void _setLocation() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LocationScreen(auth: widget.auth, current: widget.location, onSet: widget.onLocationSet),
      ),
    );
  }

  Future<void> _submit() async {
    final location = widget.location;
    if (_busy || location == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.onLoggedIn(await widget.auth.login(_loginId.text.trim(), _password.text, location: location));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(D.space6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Container(
              decoration: BoxDecoration(
                color: c.surfaceRaised,
                borderRadius: BorderRadius.circular(D.radiusLg),
                border: Border.all(color: c.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Green header with the full Altai logo.
                  Container(
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
                  Padding(
                    padding: const EdgeInsets.all(D.space8),
                    child: AutofillGroup(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('Checkout', style: AltaiType.title.copyWith(fontSize: 28, color: c.ink)),
                          Text('Log in with your Altai account.', style: AltaiType.body.copyWith(color: c.inkMuted)),
                          const SizedBox(height: D.space4),
                          _LocationRow(location: widget.location, onChange: _busy ? null : _setLocation),
                          const SizedBox(height: D.space6),
                          TextField(
                            onTap: showKeyboard,
                            controller: _loginId,
                            style: AltaiType.body.copyWith(color: c.ink),
                            decoration: const InputDecoration(
                              labelText: 'Login ID',
                              prefixIcon: Icon(Icons.person_outline_rounded),
                            ),
                            textInputAction: TextInputAction.next,
                            autocorrect: false,
                            autofillHints: const [AutofillHints.username],
                          ),
                          const SizedBox(height: D.space4),
                          TextField(
                            onTap: showKeyboard,
                            controller: _password,
                            style: AltaiType.body.copyWith(color: c.ink),
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: const Icon(Icons.lock_outline_rounded),
                              suffixIcon: IconButton(
                                tooltip: _hidePassword ? 'Show password' : 'Hide password',
                                onPressed: () => setState(() => _hidePassword = !_hidePassword),
                                icon: Icon(_hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                              ),
                            ),
                            obscureText: _hidePassword,
                            autofillHints: const [AutofillHints.password],
                            onSubmitted: (_) => _submit(),
                          ),
                          if (_error != null) ...[const SizedBox(height: D.space4), AltaiNotice(_error!)],
                          const SizedBox(height: D.space6),
                          AltaiButton(
                            _busy ? 'Logging in…' : 'Log in',
                            onPressed: _busy || widget.location == null ? null : _submit,
                            variant: AltaiButtonVariant.primary,
                            icon: Icons.login_rounded,
                            large: true,
                            expand: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Location: MidValley · Change", or a prompt to set it.
class _LocationRow extends StatelessWidget {
  const _LocationRow({required this.location, required this.onChange});

  final Store? location;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final store = location;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: D.space4, vertical: D.space3),
      decoration: BoxDecoration(
        color: store == null ? c.warningTint : c.brandTint,
        borderRadius: BorderRadius.circular(D.radiusMd),
      ),
      child: Row(
        children: [
          Icon(Icons.storefront_rounded, color: store == null ? c.warning : c.brandInk),
          const SizedBox(width: D.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('LOCATION', style: AltaiType.label.copyWith(color: c.inkMuted)),
                Text(store?.name ?? 'Not set yet', style: AltaiType.bodyStrong.copyWith(color: c.ink)),
              ],
            ),
          ),
          AltaiButton(store == null ? 'Set location' : 'Change', onPressed: onChange),
        ],
      ),
    );
  }
}

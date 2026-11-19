import 'dart:async';

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
  bool _remember = false;
  late String? _error = widget.notice;

  @override
  void initState() {
    super.initState();
    _fillRemembered();
  }

  /// "Remember me" was ticked last time: fill the login in again.
  Future<void> _fillRemembered() async {
    final saved = await widget.auth.remembered();
    if (saved == null || !mounted) return;
    setState(() {
      _loginId.text = saved.loginId;
      _password.text = saved.password;
      _remember = true;
    });
  }

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
      widget.onLoggedIn(await widget.auth.login(_loginId.text.trim(), _password.text, remember: _remember));
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
            const Align(alignment: Alignment.centerLeft, child: LogoTile(size: 56)),
            const SizedBox(height: 24),
            Text('Log in', style:AltaiType.title.copyWith(fontSize: 34, fontWeight: FontWeight.w700, color: c.ink)),
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
            const SizedBox(height: 8),
            // Fills the login in next time, also after log out.
            Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                key: const ValueKey('remember-me'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _remember = !_remember),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: Checkbox(
                          value: _remember,
                          onChanged: (v) => setState(() => _remember = v ?? false),
                          activeColor: c.brand,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('Remember me', style: AltaiType.body.copyWith(fontSize: 15, color: c.ink)),
                    ],
                  ),
                ),
              ),
            ),
            if (_error != null) ...[const SizedBox(height: D.space4), AltaiNotice(_error!)],
            const SizedBox(height: 20),
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

    return Scaffold(
      backgroundColor: c.surfaceRaised,
      body: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth >= 900) {
            // The form on the left, the photos on the right.
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(padding: const EdgeInsets.all(D.space8), child: form),
                  ),
                ),
                SizedBox(width: box.maxWidth * 0.5, child: const LoginPhotos()),
              ],
            );
          }
          // Portrait: the photos on top, the form under them.
          return SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 260, child: LoginPhotos(compact: true)),
                Padding(padding: const EdgeInsets.all(D.space8), child: form),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The photo side of the login screen: store photos that change every few seconds under a green
/// tint, with the welcome text in the middle. With the keyboard up (little height left) only the
/// name shows.
class LoginPhotos extends StatefulWidget {
  const LoginPhotos({super.key, this.compact = false, this.every = const Duration(seconds: 6)});

  /// Smaller text, for the banner on a portrait screen.
  final bool compact;

  /// How long each photo stays.
  final Duration every;

  /// The photos (free Unsplash photos, see assets/login/CREDITS.txt) and the line under each.
  static const slides = [
    ('assets/login/slide_1.jpg', 'Checkout straight from the tags.'),
    ('assets/login/slide_2.jpg', 'Returns and exchanges, checked against the order.'),
    ('assets/login/slide_3.jpg', 'Every sale matched to its receipt.'),
    ('assets/login/slide_4.jpg', 'Put the items near the reader. Altai POS does the rest.'),
  ];

  @override
  State<LoginPhotos> createState() => _LoginPhotosState();
}

class _LoginPhotosState extends State<LoginPhotos> {
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Load the next photo ahead, so the change is smooth.
    precacheImage(AssetImage(LoginPhotos.slides[(_index + 1) % LoginPhotos.slides.length].$1), context);
  }

  void _restart() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.every, (_) => _go((_index + 1) % LoginPhotos.slides.length));
  }

  void _go(int i) {
    if (!mounted) return;
    setState(() => _index = i);
    precacheImage(AssetImage(LoginPhotos.slides[(i + 1) % LoginPhotos.slides.length].$1), context);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final (photo, line) = LoginPhotos.slides[_index];
    final white = c.onLogoGreen;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: c.logoGreenBottom),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 900),
          child: Image.asset(
            photo,
            key: ValueKey(photo),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            gaplessPlayback: true,
          ),
        ),
        // The Altai green over the photo, so the white text always reads.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [c.logoGreenTop.withValues(alpha: 0.70), c.logoGreenBottom.withValues(alpha: 0.88)],
            ),
          ),
        ),
        // The big faint Altai mark behind the text.
        LayoutBuilder(
          builder: (context, box) => Center(
            child: Opacity(
              opacity: 0.08,
              child: AltaiLogo(height: (box.maxHeight * 0.7).clamp(0, 420).toDouble()),
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, box) {
            final roomy = box.maxHeight >= (widget.compact ? 200 : 420);
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.compact ? 24 : 48, vertical: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (roomy)
                    Text(
                      'WELCOME TO',
                      style: AltaiType.caption.copyWith(
                        fontSize: widget.compact ? 13 : 15,
                        letterSpacing: 4,
                        fontWeight: FontWeight.w600,
                        color: white.withValues(alpha: 0.85),
                      ),
                    ),
                  if (roomy) const SizedBox(height: 8),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'Altai POS',
                      style: AltaiType.title.copyWith(
                        fontSize: widget.compact ? 36 : 52,
                        fontWeight: FontWeight.w700,
                        color: white,
                      ),
                    ),
                  ),
                  if (roomy) ...[
                    const SizedBox(height: 16),
                    Container(width: 56, height: 3, color: white.withValues(alpha: 0.7)),
                    const SizedBox(height: 16),
                    // The line changes with the photo.
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 600),
                      child: ConstrainedBox(
                        key: ValueKey(line),
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Text(
                          line,
                          textAlign: TextAlign.center,
                          style: AltaiType.body.copyWith(
                            fontSize: widget.compact ? 15 : 18,
                            height: 1.4,
                            color: white.withValues(alpha: 0.92),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    // A dot per photo; tap one to jump to it.
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < LoginPhotos.slides.length; i++)
                          GestureDetector(
                            key: ValueKey('login-dot-$i'),
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              _go(i);
                              _restart();
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 300),
                                width: i == _index ? 24 : 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: white.withValues(alpha: i == _index ? 1 : 0.45),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

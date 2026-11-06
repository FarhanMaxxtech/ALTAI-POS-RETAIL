import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/keyboard.dart';
import '../data/auth_api.dart';
import '../domain/staff.dart';
import 'store_screen.dart';

/// Sets which store this tablet is in, once. A manager logs in here only to list the stores:
/// nobody stays logged in, and the location stays when staff log out.
class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key, required this.auth, required this.onSet, this.current});

  final AuthApi auth;
  final void Function(Store store) onSet;
  final Store? current;

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  final _loginId = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _loginId.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final stores = await widget.auth.storesFor(_loginId.text.trim(), _password.text);
      if (!mounted) return;
      final navigator = Navigator.of(context);
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => StoreScreen(
            loadStores: () async => stores,
            onPicked: (store) async {
              await widget.auth.setLocation(store);
              widget.onSet(store);
              navigator.popUntil((r) => r.isFirst); // back to the login screen
            },
          ),
        ),
      );
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final current = widget.current;
    return Scaffold(
      appBar: AltaiAppBar(title: 'Set location', onBack: () => Navigator.of(context).pop()),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(D.space6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Which store is this tablet in?', style: AltaiType.heading.copyWith(color: c.ink)),
                Text(
                  current == null
                      ? 'A manager logs in to list the stores. Staff then log in at that store.'
                      : 'Now set to ${current.name}. A manager logs in to change it.',
                  style: AltaiType.body.copyWith(color: c.inkMuted),
                ),
                const SizedBox(height: D.space6),
                TextField(
                  onTap: showKeyboard,
                  controller: _loginId,
                  style: AltaiType.body.copyWith(color: c.ink),
                  decoration: const InputDecoration(
                    labelText: 'Manager login ID',
                    prefixIcon: Icon(Icons.person_outline_rounded),
                  ),
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                ),
                const SizedBox(height: D.space4),
                TextField(
                  onTap: showKeyboard,
                  controller: _password,
                  style: AltaiType.body.copyWith(color: c.ink),
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    prefixIcon: Icon(Icons.lock_outline_rounded),
                  ),
                  obscureText: true,
                  onSubmitted: (_) => _continue(),
                ),
                if (_error != null) ...[const SizedBox(height: D.space4), AltaiNotice(_error!)],
                const SizedBox(height: D.space6),
                AltaiButton(
                  _busy ? 'Loading stores…' : 'Show stores',
                  onPressed: _busy ? null : _continue,
                  variant: AltaiButtonVariant.primary,
                  icon: Icons.storefront_rounded,
                  large: true,
                  expand: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

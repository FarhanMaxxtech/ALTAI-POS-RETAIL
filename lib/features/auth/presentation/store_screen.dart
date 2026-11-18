import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../shared/altai_theme.dart';
import '../../../shared/altai_widgets.dart';
import '../../../shared/keyboard.dart';
import '../domain/staff.dart';

/// Right after login: pick the store you're working in. Only the stores this account can use are
/// listed, the one picked last on this tablet first. An account with a single store goes straight
/// in. Every item scanned is checked against the store picked here.
class StoreScreen extends StatefulWidget {
  const StoreScreen({
    super.key,
    required this.loadStores,
    required this.onPicked,
    required this.staffName,
    this.lastStore,
    this.onLogout,
  });

  /// The stores this account can use.
  final Future<List<Store>> Function() loadStores;
  final void Function(Store store) onPicked;
  final String staffName;

  /// The store picked last on this tablet: offered first.
  final Store? lastStore;

  /// Not you, or the wrong account: back to the login screen.
  final VoidCallback? onLogout;

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  List<Store>? _stores;
  String? _error;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final stores = await widget.loadStores();
      if (!mounted) return;
      if (stores.length == 1) {
        widget.onPicked(stores.single); // nothing to choose
        return;
      }
      setState(() => _stores = stores);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    final stores = _stores;
    final error = _error;
    final last = widget.lastStore;
    // The last store first, then the rest by name.
    final sorted = stores == null
        ? const <Store>[]
        : ([...stores]..sort((a, b) {
            if (a.id == last?.id) return -1;
            if (b.id == last?.id) return 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          }));
    final q = _search.trim().toLowerCase();
    final shown = [for (final s in sorted) if (q.isEmpty || s.name.toLowerCase().contains(q)) s];

    return Scaffold(
      backgroundColor: c.surface100,
      appBar: AltaiAppBar(
        title: 'Altai POS',
        actions: [
          AppBarText(widget.staffName),
          if (widget.onLogout case final logout?)
            AppBarIcon(Icons.logout_rounded, tooltip: 'Log out', onPressed: logout),
        ],
      ),
      body: error != null
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.all(D.space6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AltaiNotice(error),
                      const SizedBox(height: D.space4),
                      AltaiButton('Try again', onPressed: _load, icon: Icons.refresh_rounded),
                    ],
                  ),
                ),
              ),
            )
          : stores == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                  children: [
                    Text('Which store are you in?',
                        style: AltaiType.title.copyWith(fontSize: 28, fontWeight: FontWeight.w700, color: c.ink)),
                    const SizedBox(height: 4),
                    Text(
                      'Every item scanned is checked against this store.',
                      style: AltaiType.body.copyWith(fontSize: 16, color: c.inkMuted),
                    ),
                    const SizedBox(height: 20),
                    if (stores.length > 6) ...[
                      TextField(
                        onTap: showKeyboard,
                        onChanged: (v) => setState(() => _search = v),
                        style: AltaiType.body.copyWith(color: c.ink),
                        decoration: const InputDecoration(
                          hintText: 'Search stores…',
                          prefixIcon: Icon(Icons.search_rounded),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (stores.isEmpty)
                      const AltaiNotice('This account has no stores. Ask your manager.', warning: true),
                    for (final s in shown)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _StoreTile(store: s, last: s.id == last?.id, onTap: () => widget.onPicked(s)),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _StoreTile extends StatelessWidget {
  const _StoreTile({required this.store, required this.onTap, this.last = false});

  final Store store;
  final VoidCallback onTap;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.altai;
    return Material(
      color: last ? c.brandTint : c.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: last ? c.brand : c.border, width: last ? 1.5 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 80),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: last ? c.surfaceRaised : c.brandTint,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.storefront_rounded, color: c.brandInk),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(store.name, style: AltaiType.bodyStrong.copyWith(color: c.ink)),
                      if (last)
                        Text('Last used on this tablet',
                            style: AltaiType.caption.copyWith(fontSize: 13, color: c.brandInk)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, size: 28, color: c.inkMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
